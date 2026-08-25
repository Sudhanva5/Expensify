// One function: take a Gmail-extracted message, run it through parser →
// categorize → DB. Idempotent on gmail message id. Returns a small summary
// for logging and the eventual silent-push step.

import type { ExtractedMessage } from '../gmail/messageBody.js';
import { isLikelyHdfcAlert } from '../gmail/messageBody.js';
import { parseHdfcEmail } from '../parsers/hdfc/index.js';
import { parseHdfcBalance } from '../parsers/hdfc/balance.js';
import { categorize } from '../categorize/index.js';
import { upsertTransaction } from '../db/transactions.js';
import { upsertAccountBalance } from '../db/accountBalances.js';
import { recordEmailMessage } from '../db/emailMessages.js';
import { prisma } from '../db/client.js';
import type { CategorizeContext, Enrichment } from '../categorize/types.js';
import type { ParsedTransaction } from '../parsers/hdfc/index.js';
import { checkBudgetForCategory } from './budgetAlerts.js';
import { sendParserMissedAlert } from '../services/apns.js';
import { initialLocationStatus } from './locationLifecycle.js';
import { bindOrphanReceiptsNear } from './bindOrphanReceipts.js';

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
      kind: 'balance_updated';
      gmailMessageId: string;
      instrument: string;
      balanceInr: number;
      asOf: string;
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
      occurredAt: string;
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

  // Balance update emails are HDFC InstaAlerts but NOT transactions —
  // they carry the account's current available balance. Run the
  // balance parser first; if it hits, we skip the transaction
  // pipeline entirely. The parser is cheap (one regex) and bailing
  // here avoids the transaction-parser cascade returning
  // no_template_match → parser-miss alert for a perfectly-recognized
  // email shape.
  const balance = parseHdfcBalance(msg.body, msg.receivedAt);
  if (balance) {
    await recordEmailMessage({
      gmailMessageId: msg.id,
      kind: 'hdfc_balance',
      parserVersion: balance.parserVersion,
      rawSubject: msg.subject,
      rawSnippet: msg.snippet || msg.body.slice(0, 200),
    });
    await upsertAccountBalance({
      instrument: balance.instrument,
      balanceInrMinor: balance.balanceInrMinor,
      asOf: balance.asOf,
      gmailMessageId: msg.id,
    });
    return {
      kind: 'balance_updated',
      gmailMessageId: msg.id,
      instrument: balance.instrument,
      balanceInr: Number(balance.balanceInrMinor) / 100,
      asOf: balance.asOf.toISOString(),
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

  const upsert = await upsertTransaction({
    parsed: parseResult.data,
    categorization,
    gmailMessageId: msg.id,
    rawSubject: msg.subject,
    rawSnippet: msg.snippet || msg.body.slice(0, 200),
  });

  if (!upsert.created) {
    return {
      kind: 'duplicate',
      gmailMessageId: msg.id,
      transactionId: upsert.id,
    };
  }

  // Sweep back for receipts that beat this bank alert. Merchants often
  // email faster than HDFC — the redBus ticket landed 21s before the debit
  // alert, so binding only at receipt-ingest time left it permanently
  // orphaned. Awaited rather than fire-and-forget so the receipt is already
  // attached by the time iOS refreshes, but wrapped so a failure here can
  // never lose the transaction we just wrote.
  if (parseResult.data.direction === 'out') {
    try {
      const sweep = await bindOrphanReceiptsNear(parseResult.data.occurredAt);
      for (const b of sweep.bound) {
        console.log(
          `[receipt-bind] late-bound ${b.source} receipt ${b.gmailMessageId} → tx ${b.transactionId} (${b.reason})`,
        );
      }
    } catch (err) {
      console.error('[receipt-bind] orphan sweep failed:', err);
    }
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

  // Mirrors the locationStatus the row was just born with — same policy
  // function, so the silent push and the DB column can never disagree.
  // Every outflow now asks; the online-merchant classifier is consulted
  // later (in recategorizeWithLocation) only to decide whether Places may
  // auto-rename the row.
  const needsLocation =
    initialLocationStatus({
      direction: parseResult.data.direction,
      isAutopay: parseResult.data.isAutopay,
    }) === 'awaiting';

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
    occurredAt: parseResult.data.occurredAt.toISOString(),
    pickedCategory: categorization.picked?.category ?? null,
    confidence: categorization.picked?.confidence ?? null,
    status: categorization.status,
    needsLocation,
  };
}
