import { describe, it, expect } from 'vitest';
import { detectOnlineMerchant } from '../../src/categorize/onlineMerchant.js';

// The detector no longer decides whether we ASK for GPS — every outflow does
// that now. It decides one narrower thing: may the Places pass silently
// RENAME + RETAG this row from whatever shop happens to be nearby?
//
// That means the only true positives are charges with no physical
// storefront at all: real websites, SaaS, and delivery/marketplace brands
// that come to you. A payment rail is NOT such a signal — Paytm, Razorpay,
// PhonePe and GPay all route in-person QR terminals as happily as they
// route web checkouts.

describe('detectOnlineMerchant — payment rails are not a signal', () => {
  // The bug this test exists for: "paytm-57338997" is the Paytm merchant
  // handle of a petrol pump in Electronic City. It matched `^PAYTM[*\s\-_]`
  // on the hyphen, so the row was born `not_applicable`, never got a GPS
  // round-trip, never got a Places suggestion, and had to be renamed
  // "E-City Petrol" by hand.
  it('does not flag a Paytm merchant handle — those are in-person terminals', () => {
    expect(detectOnlineMerchant('paytm-57338997').isOnline).toBe(false);
  });

  it('does not flag a Paytm QR handle either (already worked, must stay working)', () => {
    expect(detectOnlineMerchant('paytmqr60fsmk').isOnline).toBe(false);
  });

  it.each(['RAZ*SOMESHOP', 'GPAY-KIRANA', 'PHONEPE MERCHANT', 'PAYU*LOCALCAFE', 'CRED*SOMESHOP'])(
    'does not flag rail-prefixed payee %s',
    (payee) => {
      expect(detectOnlineMerchant(payee).isOnline).toBe(false);
    },
  );

  // The app itself is not the rail. "CRED Club" is a credit-card bill paid
  // inside the CRED app — no storefront. A shop reached THROUGH the CRED
  // rail ("CRED*SOMESHOP") is the opposite, and must stay unflagged.
  it('flags CRED Club (the app) while leaving the CRED rail alone', () => {
    expect(detectOnlineMerchant('CRED Club').isOnline).toBe(true);
    expect(detectOnlineMerchant('CRED*SOMESHOP').isOnline).toBe(false);
  });
});

describe('detectOnlineMerchant — brand token position', () => {
  // The mirror bug: HDFC put the gateway prefix first, so the `^` anchor
  // never reached the brand. "PHP*REDBUS" was treated as a physical spend
  // and fired a silent push for an online bus booking.
  it('flags a brand behind a gateway prefix', () => {
    const r = detectOnlineMerchant('PHP*REDBUS');
    expect(r.isOnline).toBe(true);
    expect(r.matched?.toUpperCase()).toContain('REDBUS');
  });

  it('flags a brand at the end of the string with no trailing delimiter', () => {
    expect(detectOnlineMerchant('PTM*SWIGGY').isOnline).toBe(true);
  });

  it('flags a bare brand with nothing around it', () => {
    expect(detectOnlineMerchant('REDBUS').isOnline).toBe(true);
  });

  it('still flags a brand at the start (the case that already worked)', () => {
    expect(detectOnlineMerchant('SWIGGY PVT LTD FOOD2').isOnline).toBe(true);
  });

  it('flags delivery + marketplace brands — the order comes to you', () => {
    for (const payee of ['ZOMATO ONLINE', 'RAZ*BLINKIT', 'MYNTRA DESIGNS', 'PTM*ZEPTO']) {
      expect(detectOnlineMerchant(payee).isOnline, payee).toBe(true);
    }
  });
});

describe('detectOnlineMerchant — no substring false positives', () => {
  // Unanchoring the brand list must not let a brand token match inside a
  // longer word. "SRI CREDIT SOCIETY" is a real-world payee and CRED is
  // on the brand list.
  it.each([
    'SRI CREDIT SOCIETY',
    'CREDAI BUILDERS',
    'UBERTO FASHIONS',
    'OLAVAKKOT STORES',
    'SQUARE MEALS RESTAURANT',
  ])('does not flag %s', (payee) => {
    expect(detectOnlineMerchant(payee).isOnline).toBe(false);
  });

  it('does not flag an ordinary local payee', () => {
    expect(detectOnlineMerchant('CTRLX TECHNOLOGIES PRIVATE LIMITED').isOnline).toBe(false);
    expect(detectOnlineMerchant('Pradeep Service Station').isOnline).toBe(false);
    expect(detectOnlineMerchant('K GANESH PAI').isOnline).toBe(false);
  });
});

describe('detectOnlineMerchant — websites', () => {
  // The original bug the whole detector exists for: a domain renewal got
  // renamed to "Vishal Mega Mart" because the user was near a supermarket.
  it('flags a domain-shaped payee', () => {
    const r = detectOnlineMerchant('NAME-CHEAP.COM* S0EXHV');
    expect(r.isOnline).toBe(true);
    expect(r.reason).toBe('tld_substring');
  });

  it('flags SaaS brands', () => {
    expect(detectOnlineMerchant('ANTHROPIC*CLAUDE').isOnline).toBe(true);
    expect(detectOnlineMerchant('NETFLIX.COM').isOnline).toBe(true);
  });

  it('handles empty input', () => {
    expect(detectOnlineMerchant('').isOnline).toBe(false);
  });
});
