// Template E v3 — RuPay CC UPI debit, June-2026 reword.
//
// HDFC InstaAlerts shipped a third generation of the CC-UPI debit
// email in June 2026, on top of:
//   • v1 ("has been debited from your HDFC Bank RuPay Credit Card XX2668")
//   • v2 ("is debited from your HDFC Bank RuPay Credit Card ending NNNN and
//          credited to VPA <vpa> (NAME) on DD Mon, YYYY")
//
// Sample (v3):
//   Subject: "❗ You have done a UPI txn. Check details!"
//   Body:
//     Dear Customer,
//     Greetings from HDFC Bank!
//     We're sharing this alert to help you quickly check a recent UPI
//     transaction made using your RuPay Credit Card.
//
//     Transaction Details:
//     Rs.110.00 has been debited from your RuPay Credit Card 2668
//     Paid to paytm-80132274@ptys
//     Date: 19-06-26
//     UPI Transaction Reference Number: 125005046968
//
// Differences absorbed here:
//   • "HDFC Bank RuPay Credit Card" → "RuPay Credit Card" (the "HDFC Bank"
//     prefix is now in the greeting line, not the debit sentence).
//   • "XX2668" / "ending 2668" → bare "2668" (no prefix at all).
//   • Payee on a separate line via "Paid to <vpa>" instead of inline
//     after "to" or "and credited to VPA".
//   • Date moved to its own line as "Date: DD-MM-YY".
//   • No payee name field. merchantRaw falls back to the VPA's
//     local-part — same fallback v2 uses when only a channel code is
//     present.

import { parseMinorUnits, parseDdMmYy } from '../dateMoney.js';
import type { HdfcEmailInput, ParseResult, TemplateParser } from '../types.js';
import { PARSER_VERSION } from '../types.js';

// Distinctive enough that order vs other templates doesn't matter —
// v1 says "HDFC Bank RuPay", v2 says "is debited", v3 says
// "We're sharing this alert" + has separate "Transaction Details:"
// section header.
const MARKER = /sharing this alert to help you quickly check a recent UPI transaction/i;

// Multi-line capture across the Transaction Details block. [\s\S]*?
// hops the line breaks between "...Credit Card NNNN", "Paid to <vpa>",
// and "Date: DD-MM-YY". Non-greedy so we stop at the first match for
// each field.
//
// Deliberately tolerant of the card-ending phrasing — HDFC has shipped
// several within the same v3 layout, so we absorb them all rather than
// add a template per reword. The "sharing this alert" MARKER already
// gates this to genuine v3 alerts, so the looseness can't catch marketing:
//   • "RuPay Credit Card 2668"            (bare)
//   • "RuPay Credit Card (ending 2668)"   (parenthesised)
//   • "RuPay Credit Card ending 2668"     (no parens)
//   • "RuPay Credit Card XX2668"          (XX prefix)
//   • optional "HDFC Bank " before "RuPay"; "has been debited"/"is debited".
const FULL =
  /Rs\.?\s*([\d,]+(?:\.\d{1,2})?)\s+(?:has been|is)\s+debited from your (?:HDFC Bank\s+)?RuPay Credit Card\s*\(?\s*(?:ending\s+|XX\s*)?(\d{4})[\s\S]*?Paid to\s+(\S+@\S+)[\s\S]*?Date:\s+(\d{2}-\d{2}-\d{2})/i;

const REF_RE = /UPI Transaction Reference Number\s*:?\s*(\d{6,})/i;

export const tryParse: TemplateParser = (
  input: HdfcEmailInput,
): ParseResult | null => {
  if (!MARKER.test(input.body)) return null;

  const m = FULL.exec(input.body);
  if (!m) {
    return {
      ok: false,
      reason: 'extraction_failed',
      details: 'main fields missing in cc_upi_debit_v3',
      parserVersion: PARSER_VERSION,
    };
  }

  const amount = parseMinorUnits(m[1]!);
  const vpa = m[3]!.trim();
  const refMatch = REF_RE.exec(input.body);

  return {
    ok: true,
    parserVersion: PARSER_VERSION,
    data: {
      template: 'cc_upi_debit_v3',
      direction: 'out',
      instrument: `card_${m[2]}`,
      amountMinor: amount,
      currency: 'INR',
      amountInrMinor: amount,
      bankConvertedRate: null,
      // No payee name in v3 — fall back to the VPA's local-part so
      // the row isn't blank. User can rename / pin a contact /
      // claim a Places suggestion as usual.
      merchantRaw: vpa.split('@')[0] ?? vpa,
      vpa,
      occurredAt: parseDdMmYy(m[4]!, input.receivedAt),
      externalRef: refMatch?.[1] ?? null,
      isAutopay: false,
    },
  };
};
