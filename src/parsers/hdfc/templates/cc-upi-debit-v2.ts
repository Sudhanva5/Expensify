// Template E.v2 — UPI debit charged to a RuPay Credit Card.
//
// HDFC rolled out a new message format around 2026-05-17. The wording
// shifted enough that the original cc_upi_debit regex no longer matches.
//
// Old (Template E):
//   "Rs.80.00 has been debited from your HDFC Bank RuPay Credit Card
//    XX2668 to paytmqr6fgl36@ptys Thimmegowda Sanjeevkumar on 27-04-26."
//
// New (Template E v2):
//   "Rs.1275.00 is debited from your HDFC Bank RuPay Credit Card
//    ending 2668 and credited to VPA paytm.d91908873@pty (TRC - QSR)
//    on 17 May, 2026."
//
// Differences absorbed here:
//   • "has been debited" → "is debited"
//   • "XX<last4>"        → "ending <last4>"
//   • "to <vpa> <name>"  → "and credited to VPA <vpa> [(code)]"
//   • date "DD-MM-YY"    → "DD Mon, YYYY" (no time field)
//
// Merchant name caveat: the new format DROPS the payee's name in
// favour of a payment-channel code like "(TRC - QSR)". We fall back to
// the VPA's local-part for merchantRaw so the row isn't blank in the
// UI; the user can claim a Places suggestion or pin a contact from
// there. VpaPattern memory still kicks in once tagged once.

import { parseMinorUnits, parseDdMonYyyy } from '../dateMoney.js';
import type { HdfcEmailInput, ParseResult, TemplateParser } from '../types.js';
import { PARSER_VERSION } from '../types.js';

const MARKER = /is debited from your HDFC Bank RuPay Credit Card/i;

// Captures: 1=amount  2=card-last4  3=vpa  4=optional payee blob  5=date
const FULL =
  /Rs\.\s*([\d,]+(?:\.\d{1,2})?)\s+is debited from your HDFC Bank RuPay Credit Card\s+ending\s+(\d+)\s+and credited to VPA\s+(\S+@\S+)\s*([^.\n]*?)\s+on\s+(\d{1,2}\s+[A-Za-z]{3},?\s+\d{4})/i;

export const tryParse: TemplateParser = (input: HdfcEmailInput): ParseResult | null => {
  if (!MARKER.test(input.body)) return null;

  const m = FULL.exec(input.body);
  if (!m) {
    return {
      ok: false,
      reason: 'extraction_failed',
      details: 'main fields missing in cc_upi_debit_v2',
      parserVersion: PARSER_VERSION,
    };
  }

  const refM = /UPI[^\d]*(\d{10,})/i.exec(input.body);
  const amount = parseMinorUnits(m[1]!);
  const vpa = m[3]!.trim();
  // Optional inline payee. New format usually has a parenthetical code
  // like "(TRC - QSR)" which is NOT a merchant name — strip it. If we
  // see a real-looking name (letters + spaces), keep it.
  const trailing = m[4]!.trim();
  const trailingWithoutParens = trailing.replace(/^\(.*?\)\s*/, '').trim();
  const looksLikeName = /^[A-Za-z][A-Za-z\s.&'/-]{2,}$/.test(trailingWithoutParens);
  const merchantRaw = looksLikeName
    ? trailingWithoutParens
    : (vpa.split('@')[0] ?? vpa);

  return {
    ok: true,
    parserVersion: PARSER_VERSION,
    data: {
      template: 'cc_upi_debit_v2',
      direction: 'out',
      instrument: `card_${m[2]}`,
      amountMinor: amount,
      currency: 'INR',
      amountInrMinor: amount,
      bankConvertedRate: null,
      merchantRaw,
      vpa,
      occurredAt: parseDdMonYyyy(m[5]!, input.receivedAt),
      externalRef: refM?.[1] ?? null,
      isAutopay: false,
    },
  };
};
