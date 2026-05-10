// Repository: log every parsed/seen Gmail message for debugging parser
// regressions and the 24-hour parser-health heartbeat.

import { prisma } from './client.js';

export interface RecordEmailInput {
  gmailMessageId: string;
  kind: string; // "hdfc_upi_credit" | "hdfc_cc_debit" | ... | "unknown"
  parserVersion: string | null;
  rawSubject: string;
  rawSnippet: string;
  parseError?: string | null;
}

export async function recordEmailMessage(
  input: RecordEmailInput,
): Promise<{ created: boolean }> {
  const existing = await prisma.emailMessage.findUnique({
    where: { gmailMessageId: input.gmailMessageId },
    select: { id: true },
  });
  if (existing) return { created: false };

  await prisma.emailMessage.create({
    data: {
      gmailMessageId: input.gmailMessageId,
      kind: input.kind,
      parsedAt: input.parserVersion ? new Date() : null,
      parserVersion: input.parserVersion,
      rawSubject: input.rawSubject,
      rawSnippet: input.rawSnippet,
      parseError: input.parseError ?? null,
    },
  });
  return { created: true };
}

// Used by the 24-hour heartbeat cron — alerts if no HDFC parse in 24 h.
export async function getMostRecentHdfcParseAt(): Promise<Date | null> {
  const row = await prisma.emailMessage.findFirst({
    where: {
      kind: { startsWith: 'hdfc_' },
      parsedAt: { not: null },
    },
    orderBy: { parsedAt: 'desc' },
    select: { parsedAt: true },
  });
  return row?.parsedAt ?? null;
}
