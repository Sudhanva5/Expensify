// Receipt pipeline. Parallel to processGmailMessage (which handles HDFC
// bank emails) — this one handles receipt emails from Swiggy, Amazon,
// Zomato, BookMyShow, etc.
//
// Flow:
//   1. Strip the HTML to plain text
//   2. Pick the right extractor (Swiggy parser, or universal fallback)
//   3. Run it — get amount, order ID, items, fees, meta
//   4. Try to bind to an HDFC transaction by amount + timestamp
//   5. Persist as EmailReceipt
//
// Idempotent on gmailMessageId — Pub/Sub at-least-once delivery is safe.

import type { ExtractedMessage } from '../gmail/messageBody.js';
import { prisma } from '../db/client.js';
import { Prisma } from '@prisma/client';
import { pickExtractor, isReceiptSender } from '../receipts/extractors.js';

export type ReceiptOutcome =
  | { kind: 'skipped_non_receipt'; gmailMessageId: string }
  | { kind: 'duplicate'; gmailMessageId: string; receiptId: string }
  | {
      kind: 'processed';
      gmailMessageId: string;
      receiptId: string;
      source: string;
      amountInrMinor: bigint | null;
      orderId: string | null;
      itemsCount: number;
      boundTransactionId: string | null;
      matchReason: 'amount_and_window' | 'amount_only' | 'no_match';
    };

/** ±30 minute matching window between receipt arrival and HDFC transaction. */
const MATCH_WINDOW_MS = 30 * 60 * 1000;

export async function processReceiptEmail(msg: ExtractedMessage): Promise<ReceiptOutcome> {
  if (!isReceiptSender(msg.fromAddress)) {
    return { kind: 'skipped_non_receipt', gmailMessageId: msg.id };
  }

  // Idempotency.
  const existing = await prisma.emailReceipt.findUnique({
    where: { gmailMessageId: msg.id },
    select: { id: true },
  });
  if (existing) {
    return { kind: 'duplicate', gmailMessageId: msg.id, receiptId: existing.id };
  }

  const { source, extract } = pickExtractor(msg.fromAddress ?? '');
  const plainText = stripHtmlToText(msg.body);
  let extracted;
  let parseError: string | null = null;
  try {
    extracted = extract(plainText);
  } catch (err) {
    parseError = (err as Error).message;
    extracted = {
      amountInrMinor: null,
      orderId: null,
      items: null,
      fees: null,
      meta: null,
      parserVersion: `${source}.failed`,
    };
  }

  // Try to bind to a recent HDFC transaction.
  const matchResult = await tryBindToTransaction({
    amountInrMinor: extracted.amountInrMinor,
    receivedAt: msg.receivedAt,
  });

  const created = await prisma.emailReceipt.create({
    data: {
      gmailMessageId: msg.id,
      source,
      subject: msg.subject,
      snippet: msg.snippet,
      receivedAt: msg.receivedAt,
      fromAddress: msg.fromAddress,
      amountInrMinor: extracted.amountInrMinor,
      orderId: extracted.orderId,
      // Prisma's JSON column type is strict — `unknown` cast first so
      // TS doesn't complain about our typed Item/Fee arrays not matching
      // the `InputJsonValue` signature (the data IS plain JSON, this is
      // a structural-typing gap on our side).
      itemsJson: (extracted.items as unknown as Prisma.InputJsonValue) ?? Prisma.JsonNull,
      feesJson: (extracted.fees as unknown as Prisma.InputJsonValue) ?? Prisma.JsonNull,
      metaJson: (extracted.meta as unknown as Prisma.InputJsonValue) ?? Prisma.JsonNull,
      parserVersion: extracted.parserVersion,
      parseError,
      transactionId: matchResult.transactionId,
    },
    select: { id: true },
  });

  return {
    kind: 'processed',
    gmailMessageId: msg.id,
    receiptId: created.id,
    source,
    amountInrMinor: extracted.amountInrMinor,
    orderId: extracted.orderId,
    itemsCount: extracted.items?.length ?? 0,
    boundTransactionId: matchResult.transactionId,
    matchReason: matchResult.reason,
  };
}

interface MatchResult {
  transactionId: string | null;
  reason: 'amount_and_window' | 'amount_only' | 'no_match';
}

/**
 * Look up an HDFC transaction that this receipt likely corresponds to.
 *
 * Strongest match: exact amount + occurredAt within ±30 minutes of when
 * the receipt landed. If exactly one transaction satisfies that,
 * unambiguous bind. If multiple satisfy, we can't disambiguate from
 * email alone — leave unbound (user can re-link manually later).
 */
async function tryBindToTransaction(opts: {
  amountInrMinor: bigint | null;
  receivedAt: Date;
}): Promise<MatchResult> {
  if (opts.amountInrMinor === null) {
    return { transactionId: null, reason: 'no_match' };
  }

  const since = new Date(opts.receivedAt.getTime() - MATCH_WINDOW_MS);
  const until = new Date(opts.receivedAt.getTime() + MATCH_WINDOW_MS);

  const candidates = await prisma.transaction.findMany({
    where: {
      amountInrMinor: opts.amountInrMinor,
      direction: 'out',
      occurredAt: { gte: since, lte: until },
    },
    select: { id: true, occurredAt: true },
    orderBy: { occurredAt: 'asc' },
  });

  if (candidates.length === 1) {
    return { transactionId: candidates[0]!.id, reason: 'amount_and_window' };
  }
  if (candidates.length === 0) {
    // Try a relaxed match — same amount, any time. If exactly one row
    // matches that's still a valid bind; banks sometimes send the alert
    // hours after the receipt for delayed authorizations.
    const sameAmount = await prisma.transaction.findMany({
      where: {
        amountInrMinor: opts.amountInrMinor,
        direction: 'out',
      },
      select: { id: true },
    });
    if (sameAmount.length === 1) {
      return { transactionId: sameAmount[0]!.id, reason: 'amount_only' };
    }
  }
  // 2+ candidates — ambiguous. Don't guess.
  return { transactionId: null, reason: 'no_match' };
}

/**
 * Cheap HTML → plain-text pass. Drops <style> and <script> blocks
 * entirely (their contents are noise), then strips tags, collapses
 * whitespace. Good enough for our regex / parser layer to work on.
 */
function stripHtmlToText(html: string): string {
  return html
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|tr|li|h[1-6])>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&#39;/gi, "'")
    .replace(/&quot;/gi, '"')
    .replace(/ /g, ' ')
    .replace(/[ \t]+/g, ' ')
    .replace(/\n\s*\n+/g, '\n')
    .trim();
}
