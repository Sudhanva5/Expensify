import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseHdfcBalance } from '../../src/parsers/hdfc/balance.js';

const FIX_DIR = join(import.meta.dirname, '../../src/parsers/__fixtures__');

const loadFixture = (name: string): string =>
  readFileSync(join(FIX_DIR, name), 'utf-8');

describe('HDFC balance parser — daily "available balance" alert', () => {
  it('parses the "The available balance ... as of DD-MMM-YY" wording', () => {
    const received = new Date('2026-07-20T02:18:00Z');
    const result = parseHdfcBalance(loadFixture('balance-as-of.txt'), received);

    expect(result).not.toBeNull();
    expect(result!.instrument).toBe('account_5264');
    expect(result!.balanceInrMinor).toBe(44514n); // ₹445.14
    expect(result!.asOf.toISOString().slice(0, 10)).toBe('2026-07-19');
  });

  // Same alert, reworded mid-July 2026: the leading "The" is gone and
  // "as of" became "as on". Everything else is identical.
  it('parses the "Available balance ... as on DD-MMM-YY" rewording', () => {
    const received = new Date('2026-07-28T02:27:59Z');
    const result = parseHdfcBalance(loadFixture('balance-as-on.txt'), received);

    expect(result).not.toBeNull();
    expect(result!.instrument).toBe('account_5264');
    expect(result!.balanceInrMinor).toBe(44514n); // ₹445.14
    expect(result!.asOf.toISOString().slice(0, 10)).toBe('2026-07-27');
  });
});

describe('HDFC balance parser — low-balance threshold alert', () => {
  // A different email shape entirely: the headline number is the *threshold*
  // (₹5,000.00), and the actual balance sits on a later line under
  // "Balance as of yesterday:". Reading the first number in the body would
  // record ₹5,000 as the balance — the bug this guards.
  it('takes the "Balance as of yesterday" figure, not the threshold', () => {
    const received = new Date('2026-07-20T02:10:21Z');
    const result = parseHdfcBalance(
      loadFixture('balance-threshold-dropped.txt'),
      received,
    );

    expect(result).not.toBeNull();
    expect(result!.instrument).toBe('account_5264');
    expect(result!.balanceInrMinor).toBe(44514n); // ₹445.14, NOT ₹5,000.00
  });

  it('dates the reading to the IST day before the email arrived', () => {
    // "yesterday" is relative — the email carries no explicit date.
    // Received 20-Jul 07:40 IST → the reading is for 19-Jul.
    const received = new Date('2026-07-20T02:10:21Z');
    const result = parseHdfcBalance(
      loadFixture('balance-threshold-dropped.txt'),
      received,
    );

    expect(result).not.toBeNull();
    expect(result!.asOf.toISOString()).toBe('2026-07-19T02:10:21.000Z');
  });
});

describe('HDFC balance parser — negative controls', () => {
  it('returns null for a transaction email', () => {
    expect(
      parseHdfcBalance(loadFixture('upi-debit-kirana.txt'), new Date()),
    ).toBeNull();
  });

  it('returns null for the debit-card ATM alert that shares the subject', () => {
    // This one also mentions an "available balance on your card" — it must
    // NOT be mistaken for an account balance alert, or the ATM withdrawal
    // would be swallowed and never become a transaction.
    expect(
      parseHdfcBalance(
        loadFixture('debit-card-atm-withdrawal.txt'),
        new Date('2026-07-05T07:22:00Z'),
      ),
    ).toBeNull();
  });

  it('returns null for unrelated marketing copy', () => {
    expect(
      parseHdfcBalance('Get 5% cashback on your next purchase!', new Date()),
    ).toBeNull();
  });
});
