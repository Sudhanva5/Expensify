// One function: take a Gmail-extracted message, run it through parser →
// categorize → DB. Idempotent on gmail message id. Returns a small summary
// for logging and the eventual silent-push step.

import type { ExtractedMessage } from '../gmail/messageBody.js';
import { isLikelyHdfcAlert } from '../gmail/messageBody.js';
import { parseHdfcEmail } from '../parsers/hdfc/index.js';
import { categorize } from '../categorize/index.js';
import { upsertTransaction } from '../db/transactions.js';
import { recordEmailMessage } from '../db/emailMessages.js';
import type { CategorizeContext, Enrichment } from '../categorize/types.js';

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

export async function processGmailMessage(
  msg: ExtractedMessage,
  ctx: CategorizeContext,
  enrichment: Enrichment = {},
): Promise<ProcessOutcome> {
  if (!isLikelyHdfcAlert(msg.fromAddress)) {
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

  const needsLocation =
    !parseResult.data.isAutopay && parseResult.data.direction === 'out';

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
