import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseHdfcEmail } from '../../src/parsers/hdfc/index.js';

const FIX_DIR = join(import.meta.dirname, '../../src/parsers/__fixtures__');

const loadFixture = (name: string): string =>
  readFileSync(join(FIX_DIR, name), 'utf-8');

describe('HDFC parser — Template A: UPI Credit', () => {
  it('parses the SNEHA R credit', () => {
    const result = parseHdfcEmail({
      subject: 'You have received money',
      body: loadFixture('upi-credit-sneha.txt'),
      receivedAt: new Date('2026-05-10T12:00:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.template).toBe('upi_credit');
    expect(result.data.direction).toBe('in');
    expect(result.data.instrument).toBe('account_5264');
    expect(result.data.amountMinor).toBe(500000n); // ₹5000.00
    expect(result.data.currency).toBe('INR');
    expect(result.data.amountInrMinor).toBe(500000n);
    expect(result.data.merchantRaw).toBe('SNEHA R');
    expect(result.data.vpa).toBe('s.neha2003rajesh-1@okaxis');
    expect(result.data.externalRef).toBe('613042740978');
    expect(result.data.isAutopay).toBe(false);
  });
});

describe('HDFC parser — Template B: Credit Card Debit', () => {
  it('parses BUNDL TECHNOLOGIES debit', () => {
    const result = parseHdfcEmail({
      subject: 'Transaction Alert',
      body: loadFixture('cc-debit-bundl.txt'),
      receivedAt: new Date('2026-05-09T05:30:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.template).toBe('cc_debit');
    expect(result.data.direction).toBe('out');
    expect(result.data.instrument).toBe('card_3328');
    expect(result.data.amountMinor).toBe(54700n); // ₹547.00
    expect(result.data.merchantRaw).toBe('BUNDL TECHNOLOGIES');
    expect(result.data.vpa).toBeNull();
    expect(result.data.isAutopay).toBe(false);

    // 09 May 2026, 10:57:54 IST = 05:27:54 UTC
    const expected = new Date(Date.UTC(2026, 4, 9, 5, 27, 54));
    expect(result.data.occurredAt.getTime()).toBe(expected.getTime());
  });

  it('parses RAZ*Swiggy debit and preserves the routing prefix in merchantRaw', () => {
    const result = parseHdfcEmail({
      subject: 'Transaction Alert',
      body: loadFixture('cc-debit-swiggy.txt'),
      receivedAt: new Date('2026-05-07T16:00:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.merchantRaw).toBe('RAZ*Swiggy');
    expect(result.data.amountMinor).toBe(21100n);
    expect(result.data.instrument).toBe('card_3328');

    const expected = new Date(Date.UTC(2026, 4, 7, 15, 45, 15));
    expect(result.data.occurredAt.getTime()).toBe(expected.getTime());
  });
});

describe('HDFC parser — Template C: CC Autopay (E-mandate)', () => {
  it('parses Anthropic autopay using "Rs." instead of "₹" for the INR conversion', () => {
    const result = parseHdfcEmail({
      subject: 'Auto-debit Confirmation',
      body: loadFixture('cc-autopay-anthropic-rs.txt'),
      receivedAt: new Date('2026-05-11T10:00:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.template).toBe('cc_autopay');
    expect(result.data.instrument).toBe('card_3803');
    expect(result.data.amountMinor).toBe(2360n); // USD 23.60
    expect(result.data.currency).toBe('USD');
    expect(result.data.amountInrMinor).toBe(223171n); // ₹2231.71
    expect(result.data.merchantRaw).toBe('Anthropic');
    expect(result.data.isAutopay).toBe(true);
    expect(result.data.bankConvertedRate).toBeCloseTo(94.56, 1);
  });

  it('parses Railway autopay with USD amount and bank-converted INR', () => {
    const result = parseHdfcEmail({
      subject: 'Auto-debit Confirmation',
      body: loadFixture('cc-autopay-railway.txt'),
      receivedAt: new Date('2026-05-05T10:00:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.template).toBe('cc_autopay');
    expect(result.data.direction).toBe('out');
    expect(result.data.instrument).toBe('card_3803');
    expect(result.data.amountMinor).toBe(500n); // USD 5.00 → 500 cents
    expect(result.data.currency).toBe('USD');
    expect(result.data.amountInrMinor).toBe(47455n); // ₹474.55
    expect(result.data.merchantRaw).toBe('Railway');
    expect(result.data.isAutopay).toBe(true);
    expect(result.data.externalRef).toBe('YE82D6dXuX');
    expect(result.data.bankConvertedRate).not.toBeNull();
    expect(result.data.bankConvertedRate!).toBeCloseTo(94.91, 1);
  });
});

describe('HDFC parser — Template D: UPI Debit', () => {
  it('parses SRI GURU RAGHAVENDRA debit (V1 phrasing: "has been debited")', () => {
    const result = parseHdfcEmail({
      subject: 'UPI Transaction Alert',
      body: loadFixture('upi-debit-kirana.txt'),
      receivedAt: new Date('2026-05-05T11:00:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.template).toBe('upi_debit');
    expect(result.data.direction).toBe('out');
    expect(result.data.instrument).toBe('account_5264');
    expect(result.data.amountMinor).toBe(9400n);
    expect(result.data.merchantRaw).toBe('SRI GURU RAGHAVENDRA ENTERPRISES');
    expect(result.data.vpa).toBe('q201985284@ybl');
    expect(result.data.externalRef).toBe('122628179659');
    expect(result.data.isAutopay).toBe(false);
  });

  it('parses small-amount transfer (V2 phrasing: "is debited from your account ending")', () => {
    const result = parseHdfcEmail({
      subject: 'You have done a UPI transaction',
      body: loadFixture('upi-debit-sneha-v2.txt'),
      receivedAt: new Date('2026-05-10T11:00:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.template).toBe('upi_debit');
    expect(result.data.direction).toBe('out');
    expect(result.data.instrument).toBe('account_5264');
    expect(result.data.amountMinor).toBe(100n); // ₹1.00
    expect(result.data.merchantRaw).toBe('SNEHA R'); // parens stripped
    expect(result.data.vpa).toBe('s.neha2003rajesh@okhdfcbank');
    expect(result.data.externalRef).toBe('649671105479');
    expect(result.data.isAutopay).toBe(false);
  });
});

describe('HDFC parser — Template D extra: paytm-VPA merchant via account', () => {
  it('parses ₹1000 to Avighna Enterprises via paytm@ptys', () => {
    const result = parseHdfcEmail({
      subject: 'UPI Transaction Alert',
      body: loadFixture('upi-debit-paytm-merchant.txt'),
      receivedAt: new Date('2026-05-04T11:00:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.data.amountMinor).toBe(100000n); // ₹1000.00
    expect(result.data.merchantRaw).toBe('Avighna Enterprises');
    expect(result.data.vpa).toBe('paytm-91206394@ptys');
    expect(result.data.instrument).toBe('account_5264');
    expect(result.data.externalRef).toBe('649006963172');
  });
});

describe('HDFC parser — Template D: CRED Club credit-card-bill payment via UPI', () => {
  it('parses ₹26,766 to cred.club@axisb (HDFC bill payment)', () => {
    const result = parseHdfcEmail({
      subject: 'UPI Transaction Alert',
      body: loadFixture('upi-debit-cred-club.txt'),
      receivedAt: new Date('2026-05-01T08:00:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.data.template).toBe('upi_debit');
    expect(result.data.amountMinor).toBe(2676600n); // ₹26,766.00
    expect(result.data.merchantRaw).toBe('CRED Club');
    expect(result.data.vpa).toBe('cred.club@axisb');
    expect(result.data.instrument).toBe('account_5264');
    expect(result.data.externalRef).toBe('648727315649');
  });
});

describe('HDFC parser — Template E: RuPay CC UPI debit', () => {
  it('parses ₹80 from RuPay XX2668 to a paytm QR merchant', () => {
    const result = parseHdfcEmail({
      subject: 'UPI Transaction Alert',
      body: loadFixture('cc-upi-debit-thimmegowda.txt'),
      receivedAt: new Date('2026-04-27T11:00:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.template).toBe('cc_upi_debit');
    expect(result.data.direction).toBe('out');
    expect(result.data.instrument).toBe('card_2668');
    expect(result.data.amountMinor).toBe(8000n); // ₹80.00
    expect(result.data.merchantRaw).toBe('Thimmegowda Sanjeevkumar');
    expect(result.data.vpa).toBe('paytmqr6fgl36@ptys');
    expect(result.data.externalRef).toBe('122213614526');
    expect(result.data.isAutopay).toBe(false);
  });
});

describe('HDFC parser — Template E v2: RuPay CC UPI debit (May 2026 format)', () => {
  it('parses the new "is debited / ending NNNN / VPA / DD Mon, YYYY" wording', () => {
    const result = parseHdfcEmail({
      subject: 'You have done a UPI txn. Check details!',
      body: loadFixture('cc-upi-debit-v2-paytm.txt'),
      receivedAt: new Date('2026-05-17T05:01:37Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.template).toBe('cc_upi_debit_v2');
    expect(result.data.direction).toBe('out');
    expect(result.data.instrument).toBe('card_2668');
    expect(result.data.amountMinor).toBe(127500n); // ₹1275.00
    expect(result.data.vpa).toBe('paytm.d91908873@pty');
    // Payment-channel code "(TRC - QSR)" is NOT a name — hyphen flags it
    // as a channel code, parser falls back to the VPA's local-part.
    expect(result.data.merchantRaw).toBe('paytm.d91908873');
    expect(result.data.externalRef).toBe('184567890123');
    expect(result.data.isAutopay).toBe(false);
  });

  it('keeps a real payee name from the parenthetical (SHANTHAMMA SM)', () => {
    // Regression: the parser used to strip the parens unconditionally,
    // even when they contained a real name like "(SHANTHAMMA SM)" —
    // merchantRaw would fall back to the VPA local-part "gpay-…".
    // Heuristic now keeps letters-only paren content and only rejects
    // codes that carry hyphens / slashes / digits ("TRC - QSR").
    const result = parseHdfcEmail({
      subject: 'You have done a UPI txn. Check details!',
      body: loadFixture('cc-upi-debit-v2-shanthamma.txt'),
      receivedAt: new Date('2026-06-11T11:56:42Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.template).toBe('cc_upi_debit_v2');
    expect(result.data.amountMinor).toBe(5800n); // ₹58.00
    expect(result.data.instrument).toBe('card_2668');
    expect(result.data.vpa).toBe('gpay-11263875094@okbizaxis');
    expect(result.data.merchantRaw).toBe('SHANTHAMMA SM');
    expect(result.data.externalRef).toBe('124572540800');
  });
});

describe('HDFC parser — Template E v3: RuPay CC UPI debit (June 2026 reword)', () => {
  it('parses the "We\'re sharing this alert" / "Paid to" / "Date:" wording', () => {
    const result = parseHdfcEmail({
      subject: '❗  You have done a UPI txn. Check details!',
      body: loadFixture('cc-upi-debit-v3-paytm.txt'),
      receivedAt: new Date('2026-06-19T16:12:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.template).toBe('cc_upi_debit_v3');
    expect(result.data.direction).toBe('out');
    expect(result.data.instrument).toBe('card_2668');
    expect(result.data.amountMinor).toBe(11000n); // ₹110.00
    expect(result.data.vpa).toBe('paytm-80132274@ptys');
    // No payee name in this format — parser falls back to the VPA's local-part.
    expect(result.data.merchantRaw).toBe('paytm-80132274');
    expect(result.data.externalRef).toBe('125005046968');
    expect(result.data.isAutopay).toBe(false);
  });

  it('parses the "(ending NNNN)" variant — no "HDFC Bank" prefix, parenthesised ending', () => {
    const result = parseHdfcEmail({
      subject: '❗  You have done a UPI txn. Check details!',
      body: loadFixture('cc-upi-debit-v3-paren.txt'),
      receivedAt: new Date('2026-06-26T16:12:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.template).toBe('cc_upi_debit_v3');
    expect(result.data.direction).toBe('out');
    expect(result.data.instrument).toBe('card_2668');
    expect(result.data.amountMinor).toBe(20000n); // ₹200.00
    expect(result.data.vpa).toBe('qexample123@ybl');
    expect(result.data.merchantRaw).toBe('qexample123');
    expect(result.data.externalRef).toBe('120000000001');
    expect(result.data.isAutopay).toBe(false);
  });
});

describe('HDFC parser — Template F: cc_thanks ("Thank you for using ...")', () => {
  it('parses the RAZ*Swiggy ₹354 alert on card ending 3328', () => {
    const result = parseHdfcEmail({
      subject: 'We noticed a transaction on your Credit Card',
      body: loadFixture('cc-thanks-swiggy.txt'),
      receivedAt: new Date('2026-06-17T15:43:00Z'),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(result.data.template).toBe('cc_thanks');
    expect(result.data.direction).toBe('out');
    expect(result.data.instrument).toBe('card_3328');
    expect(result.data.amountMinor).toBe(35400n); // ₹354.00
    expect(result.data.merchantRaw).toBe('RAZ*Swiggy');
    expect(result.data.vpa).toBeNull();
    expect(result.data.externalRef).toBe('036180'); // Authorization code
    expect(result.data.isAutopay).toBe(false);
    // 17-06-2026 21:12:59 IST → 15:42:59 UTC
    expect(result.data.occurredAt.toISOString()).toBe('2026-06-17T15:42:59.000Z');
  });

  it('does NOT match cc_debit / cc_upi_debit / cc_upi_debit_v2 emails', () => {
    // Negative control — the cc_debit fixture should never come back as
    // cc_thanks because its marker phrase is different ("has been
    // debited" vs "Thank you for using").
    const result = parseHdfcEmail({
      subject: 'Alert: You have used your HDFC Bank Card',
      body: loadFixture('cc-debit-bundl.txt'),
      receivedAt: new Date('2026-05-10T08:00:00Z'),
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.data.template).toBe('cc_debit');
  });
});

describe('HDFC parser — upcoming-autopay preview is recognized and skipped', () => {
  it('returns not_a_transaction for the heads-up email', () => {
    const result = parseHdfcEmail({
      subject: 'Upcoming E-mandate notification',
      body: loadFixture('cc-autopay-upcoming-anthropic.txt'),
      receivedAt: new Date('2026-05-10T10:00:00Z'),
    });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe('not_a_transaction');
  });

  it('does NOT misclassify the upcoming preview as cc_autopay (the actual debit)', () => {
    const result = parseHdfcEmail({
      subject: '',
      body: loadFixture('cc-autopay-upcoming-anthropic.txt'),
      receivedAt: new Date(),
    });
    expect(result.ok).toBe(false);
    if (result.ok) return;
    // The crucial check: the preview must NOT come back as a successful parse
    // (with template === cc_autopay), because then we'd insert a duplicate
    // when the actual confirmation arrives.
    expect(result.reason).toBe('not_a_transaction');
  });
});

describe('HDFC parser — robustness', () => {
  it('returns no_template_match for unrelated promotional email', () => {
    const result = parseHdfcEmail({
      subject: 'Promotional',
      body: 'Get 5% cashback on your next purchase! Visit the HDFC Bank website for details.',
      receivedAt: new Date(),
    });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe('no_template_match');
  });

  it('classifies autopay as cc_autopay, not cc_debit', () => {
    const result = parseHdfcEmail({
      subject: '',
      body: loadFixture('cc-autopay-railway.txt'),
      receivedAt: new Date(),
    });

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.data.template).toBe('cc_autopay');
  });

  it('returns extraction_failed if marker matches but body is mangled', () => {
    const result = parseHdfcEmail({
      subject: '',
      body: 'has been debited from your HDFC Bank Credit Card ending — but the rest is gone.',
      receivedAt: new Date(),
    });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe('extraction_failed');
  });
});
