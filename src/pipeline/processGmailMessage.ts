// One function: take a Gmail-extracted message, run it through parser →
// categorize → DB. Idempotent on gmail message id. Returns a small summary
// for logging and the eventual silent-push step.

import type { ExtractedMessage } from '../gmail/messageBody.js';
import { isLikelyHdfcAlert } from '../gmail/messageBody.js';
import { parseHdfcEmail } from '../parsers/hdfc/index.js';
import { categorize } from '../categorize/index.js';
import { upsertTransaction } from '../db/transactions.js';
import { recordEmailMessage } from '../db/emailMessages.js';
import { prisma } from '../db/client.js';
import type { CategorizeContext, Enrichment } from '../categorize/types.js';
import type { ParsedTransaction } from '../parsers/hdfc/index.js';
import { checkBudgetForCategory } from './budgetAlerts.js';
import { sendParserMissedAlert } from '../services/apns.js';
import { detectOnlineMerchant } from '../categorize/onlineMerchant.js';

export type ProcessOutcome =
  | {
      kind: 'skipped_non_hdfc';
      gmailMessageId: string;
      fromAddress: string | null;
    }
  | {
      kind: 'skipped_not_transaction';
      gmailMessageId: string;
      details: string;
    }
  | {
      kind: 'parse_failed';
      gmailMessageId: string;
      reason: string;
    }
  | {
      kind: 'duplicate';
      gmailMessageId: string;
      transactionId: string;
    }
  | {
      kind: 'skipped_duplicate_of_autopay';
      gmailMessageId: string;
      duplicateOfTransactionId: string;
    }
  | {
      kind: 'processed';
      gmailMessageId: string;
      transactionId: string;
      template: string;
      amountInr: number;
      currency: string;
      merchantRaw: string;
      vpa: string | null;
      direction: 'in' | 'out';
      instrument: string;
      pickedCategory: string | null;
      confidence: number | null;
      status: 'auto_resolved' | 'needs_review';
      needsLocation: boolean;
    };

// Twin detection — find the matching cc_debit ↔ cc_autopay row already in the
// DB so we either skip this insert or replace the previous one. Match window
// is 30 minutes on either side of the new row's occurredAt; banks emit both
// emails within minutes of each other.
const DUPLICATE_WINDOW_MS = 30 * 60 * 1000;

async function detectAutopayDuplicate(
  parsed: ParsedTransaction,
): Promise<
  | { action: 'skip'; keepId: string }
  | { action: 'replace'; deleteId: string }
  | null
> {
  // Match needs both sides to have an INR amount to compare against.
  if (parsed.amountInrMinor === null || parsed.amountInrMinor === undefined) {
    return null;
  }

  const since = new Date(parsed.occurredAt.getTime() - DUPLICATE_WINDOW_MS);
  const until = new Date(parsed.occurredAt.getTime() + DUPLICATE_WINDOW_MS);

  if (parsed.template === 'cc_debit') {
    // We're inserting a cc_debit — is there already a cc_autopay for the
    // same card + same INR amount within the window?
    const autopayMatch = await prisma.transaction.findFirst({
      where: {
        emailTemplate: 'cc_autopay',
        instrument: parsed.instrument,
        amountInrMinor: parsed.amountInrMinor,
        occurredAt: { gte: since, lte: until },
      },
      select: { id: true },
    });
    if (autopayMatch) return { action: 'skip', keepId: autopayMatch.id };
  }

  if (parsed.template === 'cc_autopay') {
    // We're inserting an autopay — is there a cc_debit twin already in the
    // DB? If yes, the autopay is the better record (carries source currency
    // + bank rate), so delete the twin.
    const debitMatch = await prisma.transaction.findFirst({
      where: {
        emailTemplate: 'cc_debit',
        instrument: parsed.instrument,
        amountInrMinor: parsed.amountInrMinor,
        occurredAt: { gte: since, lte: until },
      },
      select: { id: true },
    });
    if (debitMatch) return { action: 'replace', deleteId: debitMatch.id };
  }

  return null;
}

export async function processGmailMessage(
  msg: ExtractedMessage,
  ctx: CategorizeContext,
  enrichment: Enrichment = {},
): Promise<ProcessOutcome> {
  if (!isLikelyHdfcAlert(msg.fromAddress, msg.subject)) {
    return {
      kind: 'skipped_non_hdfc',
      gmailMessageId: msg.id,
      fromAddress: msg.fromAddress,
    };
  }

  const parseResult = parseHdfcEmail({
    subject: msg.subject,
    body: msg.body,
    receivedAt: msg.receivedAt,
  });

  if (!parseResult.ok) {
    // Recognized non-transaction emails (e.g., upcoming-autopay previews)
    // are skipped cleanly and logged as low-noise events.
    if (parseResult.reason === 'not_a_transaction') {
      await recordEmailMessage({
        gmailMessageId: msg.id,
        kind: 'hdfc_not_transaction',
        parserVersion: parseResult.parserVersion,
        rawSubject: msg.subject,
        rawSnippet: msg.snippet || msg.body.slice(0, 200),
      });
      return {
        kind: 'skipped_not_transaction',
        gmailMessageId: msg.id,
        details: parseResult.details,
      };
    }
    await recordEmailMessage({
      gmailMessageId: msg.id,
      kind: 'unknown_hdfc',
      parserVersion: null,
      rawSubject: msg.subject,
      rawSnippet: msg.snippet || msg.body.slice(0, 200),
      parseError: parseResult.details,
    });
    // Fire-and-forget: tell the user we just dropped a real HDFC email.
    // This is how we caught the May-2026 template change. Dedupe + APNs
    // fan-out lives inside sendParserMissedAlert — once per 24h max.
    void sendParserMissedAlert({
      gmailMessageId: msg.id,
      rawSubject: msg.subject,
      rawSnippet: msg.snippet || msg.body.slice(0, 200),
      parseError: parseResult.details,
    }).catch((err) =>
      console.error('[processGmailMessage] parser-miss alert failed:', err),
    );
    return {
      kind: 'parse_failed',
      gmailMessageId: msg.id,
      reason: `${parseResult.reason}: ${parseResult.details}`,
    };
  }

  await recordEmailMessage({
    gmailMessageId: msg.id,
    kind: `hdfc_${parseResult.data.template}`,
    parserVersion: parseResult.parserVersion,
    rawSubject: msg.subject,
    rawSnippet: msg.snippet || msg.body.slice(0, 200),
  });

  // Foreign-currency autopay charges arrive as TWO HDFC emails: the autopay
  // confirmation (cc_autopay, in source currency + INR) and a plain card-
  // debit notification (cc_debit, INR-only). They're the same charge.
  // Dedup before we insert. See detectAutopayDuplicate for the heuristic.
  const dedupTwin = await detectAutopayDuplicate(parseResult.data);
  if (dedupTwin) {
    if (dedupTwin.action === 'skip') {
      return {
        kind: 'skipped_duplicate_of_autopay',
        gmailMessageId: msg.id,
        duplicateOfTransactionId: dedupTwin.keepId,
      };
    }
    if (dedupTwin.action === 'replace') {
      // The autopay is the authoritative record (carries the original USD/EUR
      // amount). Delete the pre-existing cc_debit twin and continue inserting
      // the autopay below.
      await prisma.transaction.delete({ where: { id: dedupTwin.deleteId } });
    }
  }

  const categorization = await categorize(parseResult.data, ctx, enrichment);

  // Decide whether this row should ever receive a location update. We
  // compute it BEFORE the insert so the DB row is born with the right
  // locationStatus and iOS doesn't try to backfill it later. The only
  // skip-condition we evaluate here is the online-merchant detector
  // (.com / payment-aggregator prefix) — autopay + inbound paths are
  // handled inside upsert. Alias-resolved merchants USED to be
  // skipped too, but every in-person spend benefits from the GPS
  // ping (which Swiggy outlet, which Uber pickup) so that opt-out
  // was removed.
  const onlineCheck = detectOnlineMerchant(parseResult.data.merchantRaw);

  const upsert = await upsertTransaction({
    parsed: parseResult.data,
    categorization,
    gmailMessageId: msg.id,
    rawSubject: msg.subject,
    rawSnippet: msg.snippet || msg.body.slice(0, 200),
    isOnlineMerchant: onlineCheck.isOnline,
  });

  if (!upsert.created) {
    return {
      kind: 'duplicate',
      gmailMessageId: msg.id,
      transactionId: upsert.id,
    };
  }

  // Budget threshold check — fires an APNs push if MTD spend on this
  // category just crossed 80/100/110% for the first time this month.
  // Fire-and-forget: best-effort, never blocks the email pipeline.
  if (parseResult.data.direction === 'out' && categorization.picked) {
    const category = await prisma.category.findUnique({
      where: { name: categorization.picked.category },
      select: { id: true },
    });
    if (category) {
      void checkBudgetForCategory(category.id).catch((err) =>
        console.error('[budgetAlerts] check failed:', err),
      );
    }
  }

  // iOS-side `needsLocation` mirrors the same logic — outflow, not autopay,
  // not an online merchant, not alias-resolved.
  const needsLocation =
    !parseResult.data.isAutopay &&
    parseResult.data.direction === 'out' &&
    !onlineCheck.isOnline &&
    !aliasResolved;

  if (onlineCheck.isOnline) {
    console.log(
      `[location] skipping silent push for ${upsert.id} — online merchant (${onlineCheck.reason}: "${onlineCheck.matched}")`,
    );
  }

  const inrMinor =
    parseResult.data.amountInrMinor ?? parseResult.data.amountMinor;

  return {
    kind: 'processed',
    gmailMessageId: msg.id,
    transactionId: upsert.id,
    template: parseResult.data.template,
    amountInr: Number(inrMinor) / 100,
    currency: parseResult.data.currency,
    merchantRaw: parseResult.data.merchantRaw,
    vpa: parseResult.data.vpa,
    direction: parseResult.data.direction,
    instrument: parseResult.data.instrument,
    pickedCategory: categorization.picked?.category ?? null,
    confidence: categorization.picked?.confidence ?? null,
    status: categorization.status,
    needsLocation,
  };
}
