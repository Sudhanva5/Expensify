import { describe, it, expect } from 'vitest';
import {
  MATCH_WINDOW_MS,
  RELAXED_WINDOW_MS,
  merchantMatchesSource,
  isPersonalUpiTransfer,
  receiptAlignsWithTransaction,
} from '../../src/receipts/binding.js';

const TX_AT = new Date('2026-08-24T15:06:20.000Z');

/** The real redBus booking that stayed orphaned: ₹1355.00 on card_3803,
 *  payee "PHP*REDBUS", ticket email 4s before the HDFC alert. */
function redbusTx(over: Partial<Parameters<typeof receiptAlignsWithTransaction>[1]> = {}) {
  return {
    amountInrMinor: 135_500n,
    direction: 'out' as const,
    occurredAt: TX_AT,
    merchantRaw: 'PHP*REDBUS',
    merchantNormalized: 'redBus',
    vpa: null,
    ...over,
  };
}

function redbusReceipt(over: Partial<Parameters<typeof receiptAlignsWithTransaction>[0]> = {}) {
  return {
    amountInrMinor: 135_500n,
    receivedAt: new Date('2026-08-24T15:06:24.000Z'),
    source: 'redbus',
    ...over,
  };
}

describe('receiptAlignsWithTransaction', () => {
  it('aligns the real redBus ticket with its debit', () => {
    expect(receiptAlignsWithTransaction(redbusReceipt(), redbusTx())).toBe(true);
  });

  it('aligns regardless of which side arrived first — the predicate is symmetric in time', () => {
    // Receipt 30 min BEFORE the bank alert (the case that broke), and
    // 30 min after (the case that already worked).
    const before = new Date(TX_AT.getTime() - 30 * 60 * 1000);
    const after = new Date(TX_AT.getTime() + 30 * 60 * 1000);
    expect(receiptAlignsWithTransaction(redbusReceipt({ receivedAt: before }), redbusTx())).toBe(true);
    expect(receiptAlignsWithTransaction(redbusReceipt({ receivedAt: after }), redbusTx())).toBe(true);
  });

  it('rejects a receipt with no extractable amount', () => {
    // The redBus "Tax Invoice" email — no Ticket Price line, fell through
    // to the universal extractor, amount null. Must never bind.
    expect(receiptAlignsWithTransaction(redbusReceipt({ amountInrMinor: null }), redbusTx())).toBe(false);
  });

  it('rejects a different amount', () => {
    expect(receiptAlignsWithTransaction(redbusReceipt({ amountInrMinor: 135_400n }), redbusTx())).toBe(false);
  });

  it('rejects an inflow', () => {
    expect(receiptAlignsWithTransaction(redbusReceipt(), redbusTx({ direction: 'in' }))).toBe(false);
  });

  it('rejects a transaction with no INR amount recorded', () => {
    expect(receiptAlignsWithTransaction(redbusReceipt(), redbusTx({ amountInrMinor: null }))).toBe(false);
  });

  describe('time window', () => {
    it('rejects outside the window by default', () => {
      const far = new Date(TX_AT.getTime() + MATCH_WINDOW_MS + 1000);
      expect(receiptAlignsWithTransaction(redbusReceipt({ receivedAt: far }), redbusTx())).toBe(false);
    });

    it('accepts exactly at the window edge', () => {
      const edge = new Date(TX_AT.getTime() + MATCH_WINDOW_MS);
      expect(receiptAlignsWithTransaction(redbusReceipt({ receivedAt: edge }), redbusTx())).toBe(true);
    });

    it('accepts a next-morning delivery email under the relaxed window', () => {
      const nextMorning = new Date(TX_AT.getTime() + 14 * 60 * 60 * 1000);
      expect(
        receiptAlignsWithTransaction(redbusReceipt({ receivedAt: nextMorning }), redbusTx(), {
          windowMs: RELAXED_WINDOW_MS,
        }),
      ).toBe(true);
    });

    // The relaxed fallback used to be unbounded in time, which paired real
    // receipts with same-amount transactions 11 to 163 days apart. A ₹238
    // Swiggy order is indistinguishable from every other ₹238 Swiggy order,
    // so "same amount, any time" is not evidence of anything.
    it('rejects a same-amount pairing 11 days apart even in the relaxed pass', () => {
      const elevenDays = new Date(TX_AT.getTime() + 11 * 24 * 60 * 60 * 1000);
      expect(
        receiptAlignsWithTransaction(redbusReceipt({ receivedAt: elevenDays }), redbusTx(), {
          windowMs: RELAXED_WINDOW_MS,
        }),
      ).toBe(false);
    });

    it('disables the check only when explicitly handed null', () => {
      const far = new Date(TX_AT.getTime() + 40 * 24 * 60 * 60 * 1000);
      expect(
        receiptAlignsWithTransaction(redbusReceipt({ receivedAt: far }), redbusTx(), {
          windowMs: null,
        }),
      ).toBe(true);
    });
  });

  describe('source ↔ merchant alignment', () => {
    it('rejects a Swiggy receipt against a redBus debit', () => {
      expect(
        receiptAlignsWithTransaction(redbusReceipt({ source: 'swiggy' }), redbusTx()),
      ).toBe(false);
    });

    // The bug this guard exists for: a ₹308 Swiggy email binding to a
    // ₹308 Paytm-QR payment to "Thimmegowda".
    it('rejects a Swiggy receipt against a coincidental same-amount QR payment', () => {
      expect(
        receiptAlignsWithTransaction(
          { amountInrMinor: 30_800n, receivedAt: TX_AT, source: 'swiggy' },
          {
            amountInrMinor: 30_800n,
            direction: 'out',
            occurredAt: TX_AT,
            merchantRaw: 'THIMMEGOWDA',
            merchantNormalized: 'THIMMEGOWDA',
            vpa: 'paytmqr281005@ptys',
          },
        ),
      ).toBe(false);
    });

    it('rejects an unknown source outright rather than guessing', () => {
      expect(receiptAlignsWithTransaction(redbusReceipt({ source: 'nonesuch' }), redbusTx())).toBe(false);
    });
  });

  describe('P2P guard', () => {
    it('refuses to bind anything to a personal-VPA transfer', () => {
      expect(
        receiptAlignsWithTransaction(redbusReceipt(), redbusTx({ vpa: 'sneha.r@oksbi' })),
      ).toBe(false);
    });

    it('allows a merchant-shape VPA', () => {
      expect(
        receiptAlignsWithTransaction(redbusReceipt(), redbusTx({ vpa: 'redbus32.payu@hdfcbank' })),
      ).toBe(true);
    });
  });
});

describe('merchantMatchesSource', () => {
  it('matches the PHP*-prefixed redBus payee', () => {
    expect(merchantMatchesSource('PHP*REDBUS redBus', 'redbus')).toBe(true);
  });

  it('matches a bus operator name for a redBus receipt', () => {
    expect(merchantMatchesSource('KSRTC ONLINE', 'redbus')).toBe(true);
  });

  it('returns false for a source with no keyword table entry', () => {
    expect(merchantMatchesSource('ANYTHING', 'nonesuch')).toBe(false);
  });
});

describe('isPersonalUpiTransfer', () => {
  it('treats a null VPA as not-personal (card debits have no VPA)', () => {
    expect(isPersonalUpiTransfer(null)).toBe(false);
  });

  it('flags a personal handle', () => {
    expect(isPersonalUpiTransfer('sneha.r@oksbi')).toBe(true);
  });
});
