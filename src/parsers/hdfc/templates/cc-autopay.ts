// Template C — Credit Card Autopay (E-mandate)
// Sample marker: "set up through E-mandate (Auto payment)"
// May include foreign currency: "Amount: USD 5.00 (₹474.55)"

import { parseMinorUnits, parseDdMmYyyy } from '../dateMoney.js';
import type { HdfcEmailInput, ParseResult, TemplateParser } from '../types.js';
import { PARSER_VERSION } from '../types.js';

const MARKER = /set up through E-mandate \(Auto payment\)/i;

export const tryParse: TemplateParser = (input: HdfcEmailInput): ParseResult | null => {
  if (!MARKER.test(input.body)) return null;

  const fail = (details: string): ParseResult => ({
    ok: false,
    reason: 'extraction_failed',
    details,
    parserVersion: PARSER_VERSION,
  });

  const billM = /Your\s+(.+?)\s+bill,\s*set up through E-mandate/i.exec(input.body);
  if (!billM) return fail('bill type missing');

  const cardM = /Credit Card ending\s*(\d+)/i.exec(input.body);
  if (!cardM) return fail('card missing');

  const amountM = /Amount:\s*([A-Z]{3})\s+([\d,]+(?:\.\d{1,2})?)/i.exec(input.body);
  if (!amountM) return fail('amount missing');

  // HDFC sometimes uses ₹, sometimes "Rs.", sometimes "Rs". Accept all three.
  const inrM = /\(\s*(?:₹|Rs\.?)\s*([\d,]+(?:\.\d{1,2})?)\s*\)/.exec(input.body);

  const dateM = /Date:\s*(\d{2}\/\d{2}\/\d{4})/.exec(input.body);
  if (!dateM) return fail('date missing');

  const refM = /SI Hub ID:\s*([A-Za-z0-9]+)/i.exec(input.body);

  const currency = amountM[1]!.toUpperCase();
  const origMinor = parseMinorUnits(amountM[2]!);
  const inrMinor = inrM
    ? parseMinorUnits(inrM[1]!)
    : currency === 'INR'
      ? origMinor
      : null;

  // Bank's effective rate, in major units (e.g., 94.91 INR per USD)
  let bankRate: number | null = null;
  if (currency !== 'INR' && inrMinor !== null && origMinor > 0n) {
    bankRate = Number(inrMinor) / Number(origMinor);
  }

  return {
    ok: true,
    parserVersion: PARSER_VERSION,
    data: {
      template: 'cc_autopay',
      direction: 'out',
      instrument: `card_${cardM[1]}`,
      amountMinor: origMinor,
      currency,
      amountInrMinor: inrMinor,
      bankConvertedRate: bankRate,
      merchantRaw: billM[1]!.trim(),
      vpa: null,
      occurredAt: parseDdMmYyyy(dateM[1]!, input.receivedAt),
      externalRef: refM?.[1] ?? null,
      isAutopay: true,
    },
  };
};
