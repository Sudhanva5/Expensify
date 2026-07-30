// Template D — UPI Debit (outgoing money from HDFC account)
// Sample marker: "has been debited from account NNNN to VPA xxx"

import { parseMinorUnits, parseDdMmYy } from '../dateMoney.js';
import type { HdfcEmailInput, ParseResult, TemplateParser } from '../types.js';
import { PARSER_VERSION } from '../types.js';

// Two HDFC UPI-debit phrasings observed:
//   V1: "Rs.94.00 has been debited from account 5264 to VPA xxx PAYEE NAME on DD-MM-YY"
//   V2: "Rs.1.00 is debited from your account ending 5264 towards VPA xxx (PAYEE NAME) on DD-MM-YY"
// Differences: "has been"/"is", optional "your", optional "ending", "to"/"towards",
// payee name with or without parentheses.
const MARKER = /(?:has been|is)\s+debited from (?:your )?account/i;

const FULL = /Rs\.\s*([\d,]+(?:\.\d{1,2})?)\s+(?:has been|is)\s+debited from (?:your )?account(?:\s+ending)?\s+(\d+)\s+(?:to|towards)\s+VPA\s+(\S+)\s+(.+?)\s+on\s+(\d{2}-\d{2}-\d{2})/i;

// V3 (observed 04-Jul-2026): the destination is another bank account, not
// a VPA, so HDFC masks it and there is no payee name at all:
//   "Rs.200.00 has been debited from account 5264 to account ******* on
//    04-07-26.Your UPI transaction reference number is 618569394824."
// Note the missing space after the date's full stop — the date group is
// bounded by exactly 8 chars so it can't run into "Your".
// Captures: 1=amount  2=account-last-N  3=date
const TO_MASKED_ACCOUNT =
  /Rs\.?\s*([\d,]+(?:\.\d{1,2})?)\s+(?:has been|is)\s+debited from (?:your )?account(?:\s+ending)?\s+(\d+)\s+to\s+account\s+\S+\s+on\s+(\d{2}-\d{2}-\d{2})/i;

// Nothing in the wire text identifies the counterparty, so we don't
// invent one. A stable placeholder keeps the row readable in the UI and
// lets the merchant-pattern tier learn nothing (correctly) from it —
// the user names these by hand or via a rule.
const MASKED_PAYEE_LABEL = 'Account Transfer';

export const tryParse: TemplateParser = (input: HdfcEmailInput): ParseResult | null => {
  if (!MARKER.test(input.body)) return null;

  const m = FULL.exec(input.body);
  if (!m) {
    // Try the masked-account phrasing before giving up. Kept as a
    // separate regex rather than folding optional groups into FULL so
    // the VPA path stays the strict, unambiguous one.
    const masked = TO_MASKED_ACCOUNT.exec(input.body);
    if (masked) {
      const maskedRef = /reference[^\d]+(\d+)/i.exec(input.body);
      const maskedAmount = parseMinorUnits(masked[1]!);
      return {
        ok: true,
        parserVersion: PARSER_VERSION,
        data: {
          template: 'upi_debit',
          direction: 'out',
          instrument: `account_${masked[2]}`,
          amountMinor: maskedAmount,
          currency: 'INR',
          amountInrMinor: maskedAmount,
          bankConvertedRate: null,
          merchantRaw: MASKED_PAYEE_LABEL,
          vpa: null,
          occurredAt: parseDdMmYy(masked[3]!, input.receivedAt),
          externalRef: maskedRef?.[1] ?? null,
          isAutopay: false,
        },
      };
    }
    return {
      ok: false,
      reason: 'extraction_failed',
      details: 'main fields missing in upi_debit',
      parserVersion: PARSER_VERSION,
    };
  }

  // Handles both phrasings:
  //   V1: "UPI transaction reference number is 122628179659"
  //   V2: "UPI transaction reference no.: 649671105479"
  const refM = /reference[^\d]+(\d+)/i.exec(input.body);
  const amount = parseMinorUnits(m[1]!);

  // V2 wraps the payee in parentheses: "(SNEHA R)"; V1 doesn't.
  let merchantRaw = m[4]!.trim();
  if (merchantRaw.startsWith('(') && merchantRaw.endsWith(')')) {
    merchantRaw = merchantRaw.slice(1, -1).trim();
  }

  return {
    ok: true,
    parserVersion: PARSER_VERSION,
    data: {
      template: 'upi_debit',
      direction: 'out',
      instrument: `account_${m[2]}`,
      amountMinor: amount,
      currency: 'INR',
      amountInrMinor: amount,
      bankConvertedRate: null,
      merchantRaw,
      vpa: m[3]!.trim(),
      occurredAt: parseDdMmYy(m[5]!, input.receivedAt),
      externalRef: refM?.[1] ?? null,
      isAutopay: false,
    },
  };
};
