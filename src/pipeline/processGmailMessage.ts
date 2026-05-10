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

  return {
    kind: 'processed',
    gmailMessageId: msg.id,
    transactionId: upsert.id,
    template: parseResult.data.template,
    pickedCategory: categorization.picked?.category ?? null,
    confidence: categorization.picked?.confidence ?? null,
    status: categorization.status,
    needsLocation,
  };
}
