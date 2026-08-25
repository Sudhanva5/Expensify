// Repository: insert/update transactions. Idempotent on gmailMessageId so
// Pub/Sub at-least-once delivery doesn't create duplicates.

import { prisma } from './client.js';
import type { ParsedTransaction } from '../parsers/hdfc/index.js';
import type { CategorizationResult } from '../categorize/types.js';
import { decodeVpaMerchant } from '../categorize/vpaMerchant.js';
import { initialLocationStatus } from '../pipeline/locationLifecycle.js';

export interface InsertTransactionInput {
  parsed: ParsedTransaction;
  categorization: CategorizationResult;
  gmailMessageId: string;
  rawSubject: string;
  rawSnippet: string;
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

  // Every outflow gets the GPS round-trip. Policy (and the reasoning for
  // why the online-merchant classifier no longer has a vote here) lives in
  // pipeline/locationLifecycle.ts.
  const locationStatus = initialLocationStatus({
    direction: parsed.direction,
    isAutopay: parsed.isAutopay,
  });

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
