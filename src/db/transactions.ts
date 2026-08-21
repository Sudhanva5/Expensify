// Repository: insert/update transactions. Idempotent on gmailMessageId so
// Pub/Sub at-least-once delivery doesn't create duplicates.

import { prisma } from './client.js';
import type { ParsedTransaction } from '../parsers/hdfc/index.js';
import type { CategorizationResult } from '../categorize/types.js';
import { decodeVpaMerchant } from '../categorize/vpaMerchant.js';

export interface InsertTransactionInput {
  parsed: ParsedTransaction;
  categorization: CategorizationResult;
  gmailMessageId: string;
  rawSubject: string;
  rawSnippet: string;
  /// If true, mark locationStatus as 'not_applicable' regardless of the
  /// usual heuristic. Set by processGmailMessage for online merchants
  /// (Namecheap, Anthropic, etc.) where iPhone GPS is meaningless and
  /// would otherwise let iOS try to backfill location for the row.
  isOnlineMerchant?: boolean;
}

// Returns { id, created } — created=false means we hit the idempotency guard.
export async function upsertTransaction(
  input: InsertTransactionInput,
): Promise<{ id: string; created: boolean }> {
  const { parsed, categorization, gmailMessageId, rawSubject, rawSnippet } = input;
  const picked = categorization.picked;

  const categoryId = picked
    ? (await prisma.category.findUnique({ where: { name: picked.category } }))?.id ?? null
    : null;

  const status =
    categorization.status === 'auto_resolved' ? 'resolved' : 'pending_review';

  // Aggregator-minted VPAs name both the merchant and the rail that routed
  // the payment. Frozen onto the row at ingest so MCP can filter on gateway
  // in SQL; re-sync the whole table with scripts/backfill-vpa-merchants.ts
  // after any change to the decoder.
  const decodedVpa = parsed.vpa ? decodeVpaMerchant(parsed.vpa) : null;

  // GPS is meaningful for ANY in-person spend. We only opt out when
  // the row is structurally without a physical context:
  //   • autopay (subscription bill — billed in the cloud)
  //   • inflow (somebody paid you — you weren't necessarily anywhere)
  //   • online merchant (Namecheap, Anthropic, etc.)
  //
  // Alias-resolved merchants USED TO opt out too ("we already know
  // this is Swiggy, no need to ask the phone"), but that suppressed
  // useful context — which Swiggy outlet, which Uber pickup point,
  // which MakeMyTrip booking from where. Now alias-resolved rows
  // still go through the GPS round-trip; the user gets the physical
  // location attached to every real-world spend.
  const locationStatus =
    parsed.isAutopay ||
    parsed.direction === 'in' ||
    input.isOnlineMerchant
      ? 'not_applicable'
      : 'awaiting';

  // Try to find existing row first (idempotency)
  const existing = await prisma.transaction.findUnique({
    where: { gmailMessageId },
    select: { id: true },
  });
  if (existing) {
    return { id: existing.id, created: false };
  }

  const created = await prisma.transaction.create({
    data: {
      amountMinor: parsed.amountMinor,
      currency: parsed.currency,
      amountInrMinor: parsed.amountInrMinor,
      bankConvertedRate: parsed.bankConvertedRate,
      merchantRaw: parsed.merchantRaw,
      merchantNormalized: categorization.merchantNormalized,
      vpa: parsed.vpa,
      vpaGateway: decodedVpa?.gateway ?? null,
      vpaMerchant: decodedVpa?.merchant ?? null,
      occurredAt: parsed.occurredAt,
      direction: parsed.direction,
      instrument: parsed.instrument,
      gmailMessageId,
      emailTemplate: parsed.template,
      parserVersion: 'hdfc.v1',
      rawSubject,
      rawSnippet,
      locationStatus,
      categoryId,
      confidence: picked ? picked.confidence : null,
      signalSource: picked ? picked.source : null,
      matchedRuleId: picked?.ruleId ?? null,
      status,
    },
    select: { id: true },
  });
  return { id: created.id, created: true };
}

export async function findTransactionByGmailMessageId(
  gmailMessageId: string,
): Promise<{ id: string } | null> {
  return prisma.transaction.findUnique({
    where: { gmailMessageId },
    select: { id: true },
  });
}

export async function attachLocation(
  transactionId: string,
  lat: number,
  lng: number,
): Promise<void> {
  await prisma.transaction.update({
    where: { id: transactionId },
    data: {
      locationLat: lat,
      locationLng: lng,
      locationStatus: 'fulfilled',
    },
  });
}

export async function markLocationMissed(transactionId: string): Promise<void> {
  await prisma.transaction.update({
    where: { id: transactionId },
    data: { locationStatus: 'missed' },
  });
}

/**
 * Bulk-transition `awaiting` rows older than `cutoff` to `missed`.
 *
 * Every row born as an outflow starts `awaiting` and previously had exactly
 * one exit: a successful GPS upload from iOS. Any dropped silent push left
 * the row stuck there permanently, which (a) renders "locating…" forever in
 * the iOS chip and (b) crowds still-recoverable rows out of the `take: 50`
 * awaiting list so the foreground backfill never sees them.
 *
 * Cutoff policy lives in pipeline/locationLifecycle.ts — this is the thin
 * data-access half. Returns the number of rows transitioned.
 */
export async function expireStaleAwaitingLocations(
  cutoff: Date,
): Promise<number> {
  const result = await prisma.transaction.updateMany({
    where: {
      locationStatus: 'awaiting',
      occurredAt: { lt: cutoff },
    },
    data: { locationStatus: 'missed' },
  });
  return result.count;
}
