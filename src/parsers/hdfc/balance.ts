// HDFC balance update parser.
//
// This is NOT a transaction — it's a periodic InstaAlert that reports
// the current available balance of a savings account. Lives next to the
// transaction parsers because the sender / filter / Pub/Sub plumbing is
// identical, but produces a different shape so it's kept in its own
// file to avoid muddying the ParsedTransaction contract.
//
// Sample:
//   Subject: "View: Account update for your HDFC Bank A/c"
//   Body:
//     The available balance in your account ending XX5264 is Rs.
//     INR 747.46 as of 17-JUN-26.
//
// Quirks:
//   • Body reads "Rs. INR 747.46" — both "Rs." and "INR" appear, with
//     a literal space between. Regex tolerates either or both being
//     present.
//   • Account-ending uses "XX" prefix (e.g. "XX5264") matching the
//     existing cc_upi_debit Template-E format. Output instrument
//     shape is `account_5264` — same shape Transaction.instrument uses.

import { parseMinorUnits, parseDdMmmYy } from './dateMoney.js';
import { PARSER_VERSION } from './types.js';

export interface ParsedBalance {
  instrument: string;
  balanceInrMinor: bigint;
  asOf: Date;
  parserVersion: string;
}

const MARKER = /available balance in your account ending/i;

// Captures: 1=account-last-N  2=amount  3=date
const FULL =
  /available balance in your account ending\s+XX(\d+)\s+is\s+Rs\.\s*(?:INR\s+)?([\d,]+(?:\.\d{1,2})?)\s+as\s+of\s+(\d{1,2}-[A-Za-z]{3}-\d{2})/i;

export function parseHdfcBalance(
  body: string,
  receivedAt: Date,
): ParsedBalance | null {
  if (!MARKER.test(body)) return null;
  const m = FULL.exec(body);
  if (!m) return null;
  return {
    instrument: `account_${m[1]}`,
    balanceInrMinor: parseMinorUnits(m[2]!),
    asOf: parseDdMmmYy(m[3]!, receivedAt),
    parserVersion: PARSER_VERSION,
  };
}
