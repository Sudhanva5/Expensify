// Template H — inbound credit to the savings account (NEFT / IMPS / RTGS).
//
// Distinct from Template A (upi_credit), which only covers money arriving
// over UPI. This one is the generic "money landed in your account" alert
// and carries a bank-rail reference string instead of a VPA.
//
// Sample (observed 30-Jun-2026 — a salary credit):
//   Subject: "❗ New Deposit Alert: Check your A/c balance now!"
//   Body:
//     You have received a credit in your HDFC Bank account.
//     Details of the transaction:
//     Amount received: INR 1,34,513.00
//     Account: XX5264
//     Date: 30-JUN-2026
//     Reference Details: NEFT Cr-ICIC0099999-INTERVIEWBIT SOFTWARE
//       SERVICES PRIVATE LIMITED-S M Sudhanva Acharya-INXXXXXXXXXX4280
//     Available Balance: INR 1,35,260.46
//
// Notes:
//   • Amounts use Indian digit grouping ("1,34,513.00"). parseMinorUnits
//     strips separators wholesale, so lakh/crore grouping needs no
//     special handling.
//   • The date is DD-MMM-YYYY (four-digit year) where the balance alert
//     uses DD-MMM-YY — parseDdMmmYy accepts both.
//   • The trailing "Available Balance" is a genuine account balance, but
//     recording it would mean returning two different shapes from one
//     email. The daily balance alert already tracks that number, so it's
//     intentionally left on the floor here.

import { parseMinorUnits, parseDdMmmYy } from '../dateMoney.js';
import type { HdfcEmailInput, ParseResult, TemplateParser } from '../types.js';
import { PARSER_VERSION } from '../types.js';

const MARKER = /You have received a credit in your HDFC Bank account/i;

// Fields sit on their own lines and the order has been stable, but they're
// matched independently so a reordering or an inserted line can't break
// the whole parse.
const AMOUNT_RE = /Amount received\s*:\s*(?:INR|Rs\.?)\s*([\d,]+(?:\.\d{1,2})?)/i;
const ACCOUNT_RE = /Account\s*:\s*XX(\d+)/i;
const DATE_RE = /Date\s*:\s*(\d{1,2}-[A-Za-z]{3}-\d{2,4})/i;
const REFERENCE_RE = /Reference Details\s*:\s*(.+)/i;

// "NEFT Cr-ICIC0099999-REMITTER NAME-BENEFICIARY NAME-INXXXXXXXXXX4280"
// → "REMITTER NAME". The third hyphen-delimited field is the payer; the
// fourth is us. Only NEFT/IMPS/RTGS credits are known to use this layout,
// so anything else falls back to the raw reference line.
const RAIL_REMITTER_RE = /^(?:NEFT|IMPS|RTGS)\s+Cr-[A-Za-z0-9]+-(.+?)-/i;

export const tryParse: TemplateParser = (
  input: HdfcEmailInput,
): ParseResult | null => {
  if (!MARKER.test(input.body)) return null;

  const amountM = AMOUNT_RE.exec(input.body);
  const accountM = ACCOUNT_RE.exec(input.body);
  const dateM = DATE_RE.exec(input.body);
  if (!amountM || !accountM || !dateM) {
    return {
      ok: false,
      reason: 'extraction_failed',
      details: 'main fields missing in deposit_credit',
      parserVersion: PARSER_VERSION,
    };
  }

  const amount = parseMinorUnits(amountM[1]!);

  const reference = REFERENCE_RE.exec(input.body)?.[1]?.trim() ?? '';
  const remitter = RAIL_REMITTER_RE.exec(reference)?.[1]?.trim();
  // Without a reference line there's no payer to name; "Bank Credit" keeps
  // the row readable and reviewable rather than blank.
  const merchantRaw = remitter || reference || 'Bank Credit';

  return {
    ok: true,
    parserVersion: PARSER_VERSION,
    data: {
      template: 'deposit_credit',
      direction: 'in',
      instrument: `account_${accountM[1]}`,
      amountMinor: amount,
      currency: 'INR',
      amountInrMinor: amount,
      bankConvertedRate: null,
      merchantRaw,
      vpa: null,
      occurredAt: parseDdMmmYy(dateM[1]!, input.receivedAt),
      // The only identifier is the masked beneficiary ref
      // ("INXXXXXXXXXX4280") — not a usable external key.
      externalRef: null,
      isAutopay: false,
    },
  };
};
