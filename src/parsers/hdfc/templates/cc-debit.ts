// Template B — Credit Card Debit (merchant)
// Sample marker: "has been debited from your HDFC Bank Credit Card ending NNNN towards X"
// Note: autopay emails say "paid using" not "debited from", so they won't match.

import { parseMinorUnits, parseDdMonYyyyHms } from '../dateMoney.js';
import type { HdfcEmailInput, ParseResult, TemplateParser } from '../types.js';
import { PARSER_VERSION } from '../types.js';

const MARKER = /has been debited from your HDFC Bank Credit Card ending/i;

const FULL = /Rs\.\s*([\d,]+(?:\.\d{1,2})?)\s+has been debited from your HDFC Bank Credit Card ending\s*(\d+)\s+towards\s+(.+?)\s+on\s+(\d{1,2}\s+\w{3},\s+\d{4})\s+at\s+(\d{2}:\d{2}:\d{2})/i;

export const tryParse: TemplateParser = (input: HdfcEmailInput): ParseResult | null => {
  if (!MARKER.test(input.body)) return null;

  const m = FULL.exec(input.body);
  if (!m) {
    return {
      ok: false,
      reason: 'extraction_failed',
      details: 'main fields missing in cc_debit',
      parserVersion: PARSER_VERSION,
    };
  }

  const amount = parseMinorUnits(m[1]!);

  return {
    ok: true,
    parserVersion: PARSER_VERSION,
    data: {
      template: 'cc_debit',
      direction: 'out',
      instrument: `card_${m[2]}`,
      amountMinor: amount,
      currency: 'INR',
      amountInrMinor: amount,
      bankConvertedRate: null,
      merchantRaw: m[3]!.trim(),
      vpa: null,
      occurredAt: parseDdMonYyyyHms(m[4]!, m[5]!),
      externalRef: null,
      isAutopay: false,
    },
  };
};
