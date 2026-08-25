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
import {
  MATCH_WINDOW_MS,
  RELAXED_WINDOW_MS,
  receiptAlignsWithTransaction,
  type TransactionSide,
} from '../receipts/binding.js';

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

/**
 * Route an email to its extractor and run it. Pulled out of
 * processReceiptEmail so scripts/reextract-receipts.ts can replay the exact
 * same routing + parsing over an already-stored receipt.
 *
 * That script exists because extraction is PERSISTED at ingest and the
 * email body is not kept, so a parser fix is not retroactive and there was
 * no way to replay it. Three redBus tickets sat unbound for a month holding
 * the gross ticket price, from before `extractRedbus` learned to read
 * "Ticket Price" across a line break and subtract the coupon — the current
 * parser gets all three right. Sharing this function is what stops the
 * replay path from drifting away from the live one.
 */
export function extractReceiptFields(msg: { fromAddress: string | null; body: string }): {
  extracted: ReturnType<ReturnType<typeof pickExtractor>['extract']>;
  parseError: string | null;
  /** Post-override source: some parsers (Instamart inside the swiggy.in
   *  chain) reclassify based on body content. */
  finalSource: string;
} {
  const { source, extract } = pickExtractor(msg.fromAddress ?? '');
  const plainText = stripHtmlToText(msg.body);
  try {
    const extracted = extract(plainText);
    return {
      extracted,
      parseError: null,
      finalSource: extracted.sourceOverride ?? source,
    };
  } catch (err) {
    return {
      extracted: {
        amountInrMinor: null,
        orderId: null,
        items: null,
        fees: null,
        meta: null,
        parserVersion: `${source}.failed`,
      },
      parseError: (err as Error).message,
      finalSource: source,
    };
  }
}

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

  const { extracted, parseError, finalSource } = extractReceiptFields(msg);

  // Try to bind to a recent HDFC transaction. Pass the receipt's source
  // so we can require merchant↔source alignment (a Swiggy receipt
  // shouldn't bind to a Paytm-QR transaction with a coincidentally
  // matching amount — that's how "Thimmegowda" got tagged to a Swiggy
  // email previously).
  const matchResult = await tryBindToTransaction({
    amountInrMinor: extracted.amountInrMinor,
    receivedAt: msg.receivedAt,
    source: finalSource,
  });

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
 * Look up an HDFC transaction that this receipt likely corresponds to.
 *
 * The three guards (amount, source↔merchant alignment, non-P2P) live in
 * receipts/binding.ts so the reverse direction — bindOrphanReceiptsNear(),
 * which sweeps for receipts that arrived BEFORE their bank alert — applies
 * exactly the same rules. Prisma narrows on the cheap indexed columns here;
 * the predicate makes the actual decision.
 *
 * Exported so the reverse sweep and the backfill script share this code
 * path rather than reimplementing the "exactly one aligned candidate" rule.
 */
export async function tryBindToTransaction(opts: {
  amountInrMinor: bigint | null;
  receivedAt: Date;
  source: string;
  /** Set false to require a match inside MATCH_WINDOW_MS and skip the
   *  wider fallback. The orphan sweep and backfill pass false: they
   *  already select receipts sitting next to a transaction in time, so a
   *  relaxed hit there would be a coincidence rather than evidence. */
  allowRelaxed?: boolean;
}): Promise<MatchResult> {
  if (opts.amountInrMinor === null) {
    return { transactionId: null, reason: 'no_match' };
  }

  const receipt = {
    amountInrMinor: opts.amountInrMinor,
    receivedAt: opts.receivedAt,
    source: opts.source,
  };

  const since = new Date(opts.receivedAt.getTime() - MATCH_WINDOW_MS);
  const until = new Date(opts.receivedAt.getTime() + MATCH_WINDOW_MS);

  const CANDIDATE_FIELDS = {
    id: true,
    amountInrMinor: true,
    direction: true,
    occurredAt: true,
    merchantRaw: true,
    merchantNormalized: true,
    vpa: true,
  } as const;

  const candidates = await prisma.transaction.findMany({
    where: {
      amountInrMinor: opts.amountInrMinor,
      direction: 'out',
      occurredAt: { gte: since, lte: until },
    },
    select: CANDIDATE_FIELDS,
    orderBy: { occurredAt: 'asc' },
  });

  const aligned = candidates.filter((c) =>
    receiptAlignsWithTransaction(receipt, c as TransactionSide),
  );

  if (aligned.length === 1) {
    return { transactionId: aligned[0]!.id, reason: 'amount_and_window' };
  }
  if (aligned.length === 0 && candidates.length > 0) {
    // We had same-amount candidates but none aligned with the source —
    // reject the bind explicitly so iOS doesn't show a misleading link.
    return { transactionId: null, reason: 'source_merchant_mismatch' };
  }
  if (candidates.length === 0 && opts.allowRelaxed !== false) {
    // Relaxed match — same amount, wider window. This used to be "any
    // time", which paired receipts with same-amount transactions up to 163
    // days apart; RELAXED_WINDOW_MS caps it at 24h so a delayed bank alert
    // or a next-morning delivery email still binds, but two unrelated ₹238
    // Swiggy orders in different months cannot.
    const sameAmount = await prisma.transaction.findMany({
      where: {
        amountInrMinor: opts.amountInrMinor,
        direction: 'out',
        occurredAt: {
          gte: new Date(opts.receivedAt.getTime() - RELAXED_WINDOW_MS),
          lte: new Date(opts.receivedAt.getTime() + RELAXED_WINDOW_MS),
        },
      },
      select: CANDIDATE_FIELDS,
    });
    const sameAmountAligned = sameAmount.filter((c) =>
      receiptAlignsWithTransaction(receipt, c as TransactionSide, {
        windowMs: RELAXED_WINDOW_MS,
      }),
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
