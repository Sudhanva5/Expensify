// Template A — UPI Credit (incoming money to HDFC account)
// Sample marker: "has been successfully credited to your HDFC Bank account ending in"

import { parseMinorUnits, parseDdMmYy } from '../dateMoney.js';
import type { HdfcEmailInput, ParseResult, TemplateParser } from '../types.js';
import { PARSER_VERSION } from '../types.js';

const MARKER = /has been successfully credited to your HDFC Bank account ending in/i;

export const tryParse: TemplateParser = (input: HdfcEmailInput): ParseResult | null => {
  if (!MARKER.test(input.body)) return null;

  const fail = (details: string): ParseResult => ({
    ok: false,
    reason: 'extraction_failed',
    details,
    parserVersion: PARSER_VERSION,
  });

  const amountM = /Rs\.\s*([\d,]+(?:\.\d{1,2})?)\s+has been successfully credited/i.exec(input.body);
  if (!amountM) return fail('amount missing');

  const accountM = /account ending in\s+(\d+)/i.exec(input.body);
  if (!accountM) return fail('account missing');

  const dateM = /Date:\s*(\d{2}-\d{2}-\d{2})/.exec(input.body);
  if (!dateM) return fail('date missing');

  const senderM = /Sender:\s*(.+?)\s*\(VPA:\s*([^)]+)\)/i.exec(input.body);
  if (!senderM) return fail('sender missing');

  const refM = /UPI Reference No\.:\s*(\d+)/i.exec(input.body);

  const amount = parseMinorUnits(amountM[1]!);

  return {
    ok: true,
    parserVersion: PARSER_VERSION,
    data: {
      template: 'upi_credit',
      direction: 'in',
      instrument: `account_${accountM[1]}`,
      amountMinor: amount,
      currency: 'INR',
      amountInrMinor: amount,
      bankConvertedRate: null,
      merchantRaw: senderM[1]!.trim(),
      vpa: senderM[2]!.trim(),
      occurredAt: parseDdMmYy(dateM[1]!, input.receivedAt),
      externalRef: refM?.[1] ?? null,
      isAutopay: false,
    },
  };
};
