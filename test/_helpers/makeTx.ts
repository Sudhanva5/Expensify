import type { ParsedTransaction } from '../../src/parsers/hdfc/index.js';

export function makeTx(
  overrides: Partial<ParsedTransaction> = {},
): ParsedTransaction {
  return {
    template: 'upi_debit',
    direction: 'out',
    instrument: 'account_5264',
    amountMinor: 10000n,
    currency: 'INR',
    amountInrMinor: 10000n,
    bankConvertedRate: null,
    merchantRaw: 'TEST MERCHANT',
    vpa: null,
    occurredAt: new Date('2026-05-09T05:30:00Z'), // Sat 11:00 IST
    externalRef: null,
    isAutopay: false,
    ...overrides,
  };
}

// 2026-05-04 was a Monday.
// IST clock-time builder for tests — gives UTC date that displays as IST hh:mm.
export function istDate(
  y: number,
  m: number, // 1-12
  d: number,
  hh: number,
  mm: number,
): Date {
  const istOffsetMs = (5 * 60 + 30) * 60 * 1000;
  return new Date(Date.UTC(y, m - 1, d, hh, mm, 0) - istOffsetMs);
}
