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

// Broad enough to admit both shapes below ("available balance in your
// account ending" AND "balance in your account ending ... has dropped
// below"). Deliberately does NOT match the debit-card alert, which says
// "available balance on your card" — that one is a real transaction and
// must fall through to the parser chain.
const MARKER = /balance in your account ending/i;

// Shape 1 — the daily balance alert.
// Captures: 1=account-last-N  2=amount  3=date
//
// Tolerates the mid-July-2026 rewording, which dropped the leading
// "The" and switched "as of" → "as on". Both wordings are still in
// rotation, sometimes on consecutive days:
//   "The available balance in your account ending XX5264 is Rs. INR 445.14 as of 19-JUL-26."
//   "Available balance in your account ending XX5264 is Rs. INR 445.14 as on 27-JUL-26."
const DAILY =
  /available balance in your account ending\s+XX(\d+)\s+is\s+Rs\.?\s*(?:INR\s+)?([\d,]+(?:\.\d{1,2})?)\s+as\s+(?:of|on)\s+(\d{1,2}-[A-Za-z]{3}-\d{2})/i;

// Shape 2 — the low-balance threshold alert. Structurally different:
// the number in the headline sentence is the *threshold* the user
// configured, and the real balance appears further down under
// "Balance as of yesterday:". Two separate regexes so the threshold
// figure can never be mistaken for the balance.
//
//   "The balance in your account ending XX5264 has dropped below
//    Rs. INR 5,000.00, which is the threshold set by you.
//    Balance as of yesterday: Rs. INR 445.14"
const THRESHOLD_ACCOUNT =
  /balance in your account ending\s+XX(\d+)\s+has\s+dropped\s+below/i;
const THRESHOLD_BALANCE =
  /Balance\s+as\s+of\s+yesterday\s*:\s*Rs\.?\s*(?:INR\s+)?([\d,]+(?:\.\d{1,2})?)/i;

const ONE_DAY_MS = 24 * 60 * 60 * 1000;

export function parseHdfcBalance(
  body: string,
  receivedAt: Date,
): ParsedBalance | null {
  if (!MARKER.test(body)) return null;

  const daily = DAILY.exec(body);
  if (daily) {
    return {
      instrument: `account_${daily[1]}`,
      balanceInrMinor: parseMinorUnits(daily[2]!),
      asOf: parseDdMmmYy(daily[3]!, receivedAt),
      parserVersion: PARSER_VERSION,
    };
  }

  const acct = THRESHOLD_ACCOUNT.exec(body);
  const bal = acct ? THRESHOLD_BALANCE.exec(body) : null;
  if (acct && bal) {
    return {
      instrument: `account_${acct[1]}`,
      balanceInrMinor: parseMinorUnits(bal[1]!),
      // "yesterday" is relative — this email carries no explicit date.
      // IST has no DST, so subtracting exactly 24h lands on the previous
      // IST calendar day at the same clock time, which is the same
      // convention parseDdMmmYy uses for the daily alert (calendar date
      // + time-of-day inherited from receivedAt).
      asOf: new Date(receivedAt.getTime() - ONE_DAY_MS),
      parserVersion: PARSER_VERSION,
    };
  }

  return null;
}
