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
      matchReason: 'amount_and_window' | 'amount_only' | 'no_match' | 'source_merchant_mismatch';
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

  // Try to bind to a recent HDFC transaction. Pass the receipt's source
  // so we can require merchant↔source alignment (a Swiggy receipt
  // shouldn't bind to a Paytm-QR transaction with a coincidentally
  // matching amount — that's how "Thimmegowda" got tagged to a Swiggy
  // email previously).
  const matchResult = await tryBindToTransaction({
    amountInrMinor: extracted.amountInrMinor,
    receivedAt: msg.receivedAt,
    source: extracted.sourceOverride ?? source,
  });

  // Some parsers (e.g. Instamart inside the swiggy.in chain) reclassify
  // the source based on body content. Honour the override when set.
  const finalSource = extracted.sourceOverride ?? source;

  const created = await prisma.emailReceipt.create({
    data: {
      gmailMessageId: msg.id,
      source: finalSource,
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
    source: finalSource,
    amountInrMinor: extracted.amountInrMinor,
    orderId: extracted.orderId,
    itemsCount: extracted.items?.length ?? 0,
    boundTransactionId: matchResult.transactionId,
    matchReason: matchResult.reason,
  };
}

interface MatchResult {
  transactionId: string | null;
  reason: 'amount_and_window' | 'amount_only' | 'no_match' | 'source_merchant_mismatch';
}

/**
 * Per-source merchant keywords that a receipt's matched transaction
 * MUST contain in its `merchantNormalized` or `merchantRaw`. Without
 * this, a Swiggy receipt for ₹200 could bind to ANY ₹200 outbound
 * transaction in the window — including offline kirana payments via
 * Paytm-QR that happen to have the same amount.
 */
const SOURCE_MERCHANT_KEYWORDS: Record<string, RegExp> = {
  swiggy: /swiggy|bundl/i,
  instamart: /swiggy|instamart|bundl/i,
  zomato: /zomato/i,
  amazon: /amazon|amzn/i,
  bookmyshow: /bookmyshow|bms/i,
  uber: /uber/i,
  cab: /uber|ola|rapido/i,
  travel: /makemytrip|goibibo|cleartrip|easemytrip|irctc|indigo|akasa|vistara/i,
  airbnb: /airbnb/i,
  shopping: /amazon|flipkart|myntra|jiomart/i,
  grocery: /bigbasket|blinkit|zepto|dmart|reliance/i,
};

/** Returns true when the transaction's merchant text aligns with the source. */
function merchantMatchesSource(merchant: string, source: string): boolean {
  const re = SOURCE_MERCHANT_KEYWORDS[source];
  if (!re) return false; // unknown source → don't bind (safer)
  return re.test(merchant);
}

/**
 * Look up an HDFC transaction that this receipt likely corresponds to.
 *
 * Match requires:
 *   1. Exact amount match
 *   2. occurredAt within ±30 minutes of receipt arrival (or amount-only
 *      fallback when window match yields nothing)
 *   3. **Merchant ↔ source alignment** — the transaction's merchantRaw
 *      or merchantNormalized must mention a keyword for the receipt's
 *      source. A Swiggy receipt can only bind to a transaction whose
 *      merchant text mentions Swiggy/Bundl. Without this guard, random
 *      same-amount coincidences bind incorrectly (the "Thimmegowda
 *      got a Swiggy email tagged to it" class of bug).
 */
async function tryBindToTransaction(opts: {
  amountInrMinor: bigint | null;
  receivedAt: Date;
  source: string;
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
    select: { id: true, occurredAt: true, merchantRaw: true, merchantNormalized: true },
    orderBy: { occurredAt: 'asc' },
  });

  // Require merchant↔source alignment.
  const aligned = candidates.filter((c) =>
    merchantMatchesSource(`${c.merchantRaw} ${c.merchantNormalized}`, opts.source),
  );

  if (aligned.length === 1) {
    return { transactionId: aligned[0]!.id, reason: 'amount_and_window' };
  }
  if (aligned.length === 0 && candidates.length > 0) {
    // We had same-amount candidates but none aligned with the source —
    // reject the bind explicitly so iOS doesn't show a misleading link.
    return { transactionId: null, reason: 'source_merchant_mismatch' };
  }
  if (candidates.length === 0) {
    // Relaxed match — same amount, any time. Still requires source alignment.
    const sameAmount = await prisma.transaction.findMany({
      where: {
        amountInrMinor: opts.amountInrMinor,
        direction: 'out',
      },
      select: { id: true, merchantRaw: true, merchantNormalized: true },
    });
    const sameAmountAligned = sameAmount.filter((c) =>
      merchantMatchesSource(`${c.merchantRaw} ${c.merchantNormalized}`, opts.source),
    );
    if (sameAmountAligned.length === 1) {
      return { transactionId: sameAmountAligned[0]!.id, reason: 'amount_only' };
    }
  }
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
