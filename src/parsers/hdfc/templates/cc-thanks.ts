// Template F — Credit Card "Thank you for using" alert.
//
// HDFC InstaAlerts sends a third CC-charge format alongside the older
// "debited from your HDFC Bank Credit Card ending NNNN towards X" (Template B)
// and the UPI variants. This one reads as a positive-tone confirmation
// rather than a debit notification.
//
// Sample:
//   Subject: "We noticed a transaction on your Credit Card"
//   Body:
//     Thank you for using your HDFC Bank Credit Card ending in 3328.
//     You made a transaction of Rs. 354.00 at RAZ*Swiggy on
//     17-06-2026 21:12:59.
//     Authorization code: 036180
//
// Distinctive markers vs the older CC templates:
//   • Phrase: "Thank you for using your HDFC Bank Credit Card ending in"
//     (others use "debited from your HDFC Bank Credit Card ending NNNN
//     towards X" or "has been debited from your HDFC Bank RuPay Credit
//     Card XX..." or "is debited from your HDFC Bank RuPay Credit Card
//     ending NNNN and credited to VPA ...").
//   • Date format: "DD-MM-YYYY HH:MM:SS" — neither "DD-MM-YY" (upi_debit /
//     cc_upi_debit) nor "DD Mon, YYYY" (cc_upi_debit_v2) nor "DD MMM, YYYY
//     at HH:MM:SS" (cc_debit).
//   • Carries an "Authorization code: NNNNNN" instead of a UPI reference.
//
// Authorization code surfaces as `externalRef` (same shape as the UPI
// reference number) so downstream code doesn't need to learn a new
// field for it.

import { parseMinorUnits, parseDdMmYyyyHms } from '../dateMoney.js';
import type { HdfcEmailInput, ParseResult, TemplateParser } from '../types.js';
import { PARSER_VERSION } from '../types.js';

const MARKER = /Thank you for using your HDFC Bank Credit Card ending in/i;

// Captures: 1=card-last4  2=amount  3=merchantRaw  4=date+time
//
// `\s*\.?\s*` between the card number and "You made" is deliberate: the
// HTML version of this email renders as "...ending in 3328.You made"
// (no space around the period). Plain-text mailers will have a space;
// both pass.
const FULL =
  /Thank you for using your HDFC Bank Credit Card ending in\s+(\d+)\s*\.?\s*You made a transaction of\s+Rs\.\s*([\d,]+(?:\.\d{1,2})?)\s+at\s+(.+?)\s+on\s+(\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}:\d{2})/i;

const AUTH_RE = /Authorization code:\s*(\d+)/i;

export const tryParse: TemplateParser = (
  input: HdfcEmailInput,
): ParseResult | null => {
  if (!MARKER.test(input.body)) return null;

  const m = FULL.exec(input.body);
  if (!m) {
    return {
      ok: false,
      reason: 'extraction_failed',
      details: 'main fields missing in cc_thanks',
      parserVersion: PARSER_VERSION,
    };
  }

  const amount = parseMinorUnits(m[2]!);
  const authMatch = AUTH_RE.exec(input.body);

  return {
    ok: true,
    parserVersion: PARSER_VERSION,
    data: {
      template: 'cc_thanks',
      direction: 'out',
      instrument: `card_${m[1]}`,
      amountMinor: amount,
      currency: 'INR',
      amountInrMinor: amount,
      bankConvertedRate: null,
      merchantRaw: m[3]!.trim(),
      vpa: null,
      occurredAt: parseDdMmYyyyHms(m[4]!),
      externalRef: authMatch?.[1] ?? null,
      isAutopay: false,
    },
  };
};
