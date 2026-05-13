// Repository: insert/update transactions. Idempotent on gmailMessageId so
// Pub/Sub at-least-once delivery doesn't create duplicates.

import { prisma } from './client.js';
import type { ParsedTransaction } from '../parsers/hdfc/index.js';
import type { CategorizationResult } from '../categorize/types.js';

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
  /// If true, the categorization came from an alias hit and we're already
  /// confident — no need to ask the phone for location. Same semantic
  /// effect as isOnlineMerchant: locationStatus becomes 'not_applicable'.
  isAliasResolved?: boolean;
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

  const locationStatus =
    parsed.isAutopay ||
    parsed.direction === 'in' ||
    input.isOnlineMerchant ||
    input.isAliasResolved
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
