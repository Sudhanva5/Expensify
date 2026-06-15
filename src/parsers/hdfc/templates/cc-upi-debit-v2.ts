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
// Merchant name caveat: the parenthetical after the VPA carries one of
// two distinct things:
//   • a real payee name — "(SHANTHAMMA SM)", "(BIG BAZAAR LTD)" — when
//     paying a person or named merchant
//   • a payment-channel code — "(TRC - QSR)", "(QR - F&B)" — when paying
//     a paytm-QR / GPay-QR-style merchant where the bank doesn't have
//     the storefront name
// Distinguishing them by content: real names are letters + spaces (with
// optional apostrophes / periods / ampersands); channel codes carry
// hyphens, slashes, or digits. When the paren content fails the
// "looks like a name" check we fall back to the VPA's local-part so
// the row isn't blank; user can rename or claim a Places suggestion.

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
  // Prefer the parenthetical (real payee name); fall back to the bare
  // trailing text; fall back finally to the VPA's local-part. Each
  // candidate runs through looksLikePayeeName(), which rejects
  // payment-channel codes like "TRC - QSR" without giving up real names
  // like "SHANTHAMMA SM".
  const trailing = m[4]!.trim();
  const parenContent = /^\(([^)]+)\)/.exec(trailing)?.[1]?.trim();
  const bareTrailing = trailing.startsWith('(') ? undefined : trailing;
  const nameCandidate =
    (parenContent && looksLikePayeeName(parenContent) && parenContent) ||
    (bareTrailing && looksLikePayeeName(bareTrailing) && bareTrailing) ||
    null;
  const merchantRaw = nameCandidate ?? vpa.split('@')[0] ?? vpa;

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

/// True when the string is plausibly a human/business name rather than a
/// payment-channel code. Letters + the punctuation real names carry
/// (space, period, apostrophe, ampersand) only — hyphens, slashes, and
/// digits flag the value as a code like "TRC - QSR" or "QR - F&B".
function looksLikePayeeName(s: string): boolean {
  const t = s.trim();
  if (t.length < 3) return false;
  return /^[A-Za-z][A-Za-z\s.'&]+$/.test(t);
}
