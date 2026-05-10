// Template E — UPI debit charged to a RuPay Credit Card.
//
// Sample:
//   "Rs.80.00 has been debited from your HDFC Bank RuPay Credit Card XX2668
//    to paytmqr6fgl36@ptys Thimmegowda Sanjeevkumar on 27-04-26.
//    Your UPI transaction reference number is 122213614526."
//
// This is structurally a UPI debit (VPA + payee) but the source instrument is
// a credit card, not a bank account. RuPay credit cards support UPI in India.
// Card number arrives masked as "XX<last4>" — we keep just the last 4.

import { parseMinorUnits, parseDdMmYy } from '../dateMoney.js';
import type { HdfcEmailInput, ParseResult, TemplateParser } from '../types.js';
import { PARSER_VERSION } from '../types.js';

const MARKER = /has been debited from your HDFC Bank RuPay Credit Card/i;

const FULL =
  /Rs\.\s*([\d,]+(?:\.\d{1,2})?)\s+has been debited from your HDFC Bank RuPay Credit Card\s+XX(\d+)\s+to\s+(\S+@\S+)\s+(.+?)\s+on\s+(\d{2}-\d{2}-\d{2})/i;

export const tryParse: TemplateParser = (input: HdfcEmailInput): ParseResult | null => {
  if (!MARKER.test(input.body)) return null;

  const m = FULL.exec(input.body);
  if (!m) {
    return {
      ok: false,
      reason: 'extraction_failed',
      details: 'main fields missing in cc_upi_debit',
      parserVersion: PARSER_VERSION,
    };
  }

  const refM = /reference[^\d]+(\d+)/i.exec(input.body);
  const amount = parseMinorUnits(m[1]!);

  return {
    ok: true,
    parserVersion: PARSER_VERSION,
    data: {
      template: 'cc_upi_debit',
      direction: 'out',
      instrument: `card_${m[2]}`,
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
