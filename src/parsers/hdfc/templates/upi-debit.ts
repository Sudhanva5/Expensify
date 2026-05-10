// Template D — UPI Debit (outgoing money from HDFC account)
// Sample marker: "has been debited from account NNNN to VPA xxx"

import { parseMinorUnits, parseDdMmYy } from '../dateMoney.js';
import type { HdfcEmailInput, ParseResult, TemplateParser } from '../types.js';
import { PARSER_VERSION } from '../types.js';

const MARKER = /has been debited from account\s+\d/i;

const FULL = /Rs\.\s*([\d,]+(?:\.\d{1,2})?)\s+has been debited from account\s+(\d+)\s+to VPA\s+(\S+)\s+(.+?)\s+on\s+(\d{2}-\d{2}-\d{2})/i;

export const tryParse: TemplateParser = (input: HdfcEmailInput): ParseResult | null => {
  if (!MARKER.test(input.body)) return null;

  const m = FULL.exec(input.body);
  if (!m) {
    return {
      ok: false,
      reason: 'extraction_failed',
      details: 'main fields missing in upi_debit',
      parserVersion: PARSER_VERSION,
    };
  }

  const refM = /UPI transaction reference number is\s+(\d+)/i.exec(input.body);
  const amount = parseMinorUnits(m[1]!);

  return {
    ok: true,
    parserVersion: PARSER_VERSION,
    data: {
      template: 'upi_debit',
      direction: 'out',
      instrument: `account_${m[2]}`,
      amountMinor: amount,
      currency: 'INR',
      amountInrMinor: amount,
      bankConvertedRate: null,
      merchantRaw: m[4]!.trim(),
      vpa: m[3]!.trim(),
      occurredAt: parseDdMmYy(m[5]!, input.receivedAt),
      externalRef: refM?.[1] ?? null,
      isAutopay: false,
    },
  };
};
