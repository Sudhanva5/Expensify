// Template G — Debit Card alert (ATM withdrawal / POS purchase).
//
// The debit-card sibling of Template F (cc_thanks). Same "Thank you for
// using your HDFC Bank ..." opening, but the card is a Debit Card and the
// sentence carries a transaction *kind* ("ATM withdrawal") plus a city.
//
// Sample (observed 05-Jul-2026):
//   Subject: "View: Account update for your HDFC Bank A/c"
//   Body:
//     Dear Card Holder,
//     Thank you for using your HDFC Bank Debit Card ending 6812 for ATM
//     withdrawal for Rs 800.00 in UDUPI at SALMAR KARKALA ATM on
//     05-07-2026 12:52:09.
//     After the above transaction, the total available balance on your
//     card is Rs 9580.53.
//
// Two things worth knowing:
//   • The SUBJECT is the same one HDFC uses for the daily account-balance
//     alert, so the subject is useless as a discriminator here. Only the
//     body marker separates them. (That shared subject is also why the
//     balance parser must not claim this email — it mentions an
//     "available balance", but "on your card", not "in your account
//     ending". See balance.ts.)
//   • "Rs 800.00" has no full stop after "Rs", unlike every other HDFC
//     template. The amount regex tolerates both.
//
// The trailing available-balance figure is deliberately NOT persisted to
// AccountBalance: it reads "balance on your card", which for this card
// did not agree with the account-level balance alerts from the same
// period. Recording it would corrupt the account balance with a
// different quantity.

import { parseMinorUnits, parseDdMmYyyyHms } from '../dateMoney.js';
import type { HdfcEmailInput, ParseResult, TemplateParser } from '../types.js';
import { PARSER_VERSION } from '../types.js';

const MARKER = /Thank you for using your HDFC Bank Debit Card ending/i;

// Captures: 1=card-last4  2=amount  3=merchant  4=date+time
//
// The "<kind> for" segment ("ATM withdrawal for", "a purchase of") is
// skipped with a non-greedy `.+?`; the city between "in" and "at" is
// likewise passed over — ParsedTransaction has no city field, and GPS
// from the silent push is a better location signal than the bank's.
const WITH_CITY =
  /Thank you for using your HDFC Bank Debit Card ending\s+(\d+)\s+for\s+.+?\s+for\s+Rs\.?\s*([\d,]+(?:\.\d{1,2})?)\s+in\s+.+?\s+at\s+(.+?)\s+on\s+(\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}:\d{2})/i;

// Same sentence without the "in <city>" clause. Tried second so the
// city-bearing form can't have its merchant capture swallow "UDUPI at".
const WITHOUT_CITY =
  /Thank you for using your HDFC Bank Debit Card ending\s+(\d+)\s+for\s+.+?\s+for\s+Rs\.?\s*([\d,]+(?:\.\d{1,2})?)\s+at\s+(.+?)\s+on\s+(\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}:\d{2})/i;

export const tryParse: TemplateParser = (
  input: HdfcEmailInput,
): ParseResult | null => {
  if (!MARKER.test(input.body)) return null;

  const m = WITH_CITY.exec(input.body) ?? WITHOUT_CITY.exec(input.body);
  if (!m) {
    return {
      ok: false,
      reason: 'extraction_failed',
      details: 'main fields missing in debit_card',
      parserVersion: PARSER_VERSION,
    };
  }

  const amount = parseMinorUnits(m[2]!);

  return {
    ok: true,
    parserVersion: PARSER_VERSION,
    data: {
      template: 'debit_card',
      direction: 'out',
      instrument: `card_${m[1]}`,
      amountMinor: amount,
      currency: 'INR',
      amountInrMinor: amount,
      bankConvertedRate: null,
      merchantRaw: m[3]!.trim(),
      vpa: null,
      occurredAt: parseDdMmYyyyHms(m[4]!),
      // Debit-card alerts carry no UPI reference or authorization code.
      externalRef: null,
      isAutopay: false,
    },
  };
};
