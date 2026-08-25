import { describe, it, expect } from 'vitest';
import { detectMarketingReceipt, normalizeSubject } from '../../src/receipts/marketing.js';

// Every "keeps" case below is a subject that really did bind to a
// transaction, so misclassifying one is a data-loss bug, not a nit.
describe('detectMarketingReceipt — must never reject a real receipt', () => {
  it.each([
    ['Your Swiggy order was successfully delivered', 'Swiggy <noreply@swiggy.in>'],
    ['Your Swiggy order was delivered before time', 'Swiggy <noreply@swiggy.in>'],
    ['Your Swiggy Gourmet order was delivered superfast', 'Swiggy <noreply@swiggy.in>'],
    ['Your Swiggy order no. #239991815544676 has been cancelled', 'Swiggy <noreply@swiggy.in>'],
    ['Your Instamart order was successfully delivered', 'Swiggy <noreply@instamart.in>'],
    ['redBus Ticket - TV6J17963815', 'redBus <no-reply@redbus.in>'],
    ['redBus - Tax Invoice', 'redBus <no-reply@redbus.in>'],
    ['Confirmed: Your June 13 – 14 trip, here’s your Airbnb receipt', 'Airbnb <automated@airbnb.com>'],
    ['Your M-Express order item has been shipped.', 'Myntra <updates@myntra.com>'],
    ['Your M-Express order item is out for delivery', 'Myntra <updates@myntra.com>'],
    [
      'Your Booking Confirmation Voucher for Super Collection O Technopark',
      'MakeMyTrip <noreply@makemytrip.com>',
    ],
    ['Amazon Web Services GST Invoice Available', 'AWS <no-reply-aws@amazon.com>'],
    ['Tax Invoice for your Hotel Booking id NH1234', 'Goibibo <noreply@makemytrip.com>'],
  ])('keeps %s', (subject, from) => {
    expect(detectMarketingReceipt(from, subject).isMarketing).toBe(false);
  });

  // A receipt may legitimately mention a discount it applied, and "₹120
  // off" is also textbook campaign language. The transactional marker
  // ("order … delivered") has to win, otherwise tuning the marketing
  // patterns tightly enough to thread that needle becomes endless.
  it('keeps an order confirmation that also mentions a discount', () => {
    expect(
      detectMarketingReceipt(
        'Swiggy <noreply@swiggy.in>',
        'Your Swiggy order was delivered — ₹120 off applied',
      ).isMarketing,
    ).toBe(false);
  });

  it('keeps a receipt even from an otherwise non-transactional sender', () => {
    expect(
      detectMarketingReceipt('Feedback redBus <no_reply_feedback@redbus.in>', 'redBus - Tax Invoice')
        .isMarketing,
    ).toBe(false);
  });
});

describe('detectMarketingReceipt — rejects the promo class', () => {
  it('rejects the perfume ad that started this', () => {
    const r = detectMarketingReceipt('Myntra <updates@myntra.com>', 'Festive Bash: Ends Tonight⏰');
    expect(r.isMarketing).toBe(true);
    expect(r.reason).toBe('marketing_subject');
  });

  // The dangerous one: the universal extractor pulled ₹850 out of this ad,
  // and a ₹850 figure invented by marketing could bind to a real ₹850 debit.
  it('rejects the promo whose body yielded a bogus ₹850', () => {
    expect(
      detectMarketingReceipt(
        'Feedback redBus <no_reply_feedback@redbus.in>',
        'Here’s how you can get a FREE bus ticket! 👇',
      ).isMarketing,
    ).toBe(true);
  });

  it.each([
    ['Sudhanva Acharya, Rate your experience with redBus!', 'redBus <no-reply@redbus.in>'],
    ['Sudhanva Acharya, here’s everything you need for your trip to Karkala', 'redBus <no-reply@redbus.in>'],
    ['Alert : Payment Failed for your Order #246031926133137', 'Swiggy <noreply@swiggy.in>'],
    ['Sudhanva Acharya, you are now a Swiggy One Black member!', 'Swiggy <no-reply@swiggy.in>'],
    ['LIVE NOW: Min. 10% OFF* on International Flights', 'MMT <noreply@zen-makemytrip.com>'],
    ['📢BIGGEST PRICE DROP ALERT ON FLIGHTS✈️', 'MMT <noreply@zen-makemytrip.com>'],
    ['Right To Fashion Sale Is LIVE 🇮🇳', 'Myntra <updates@myntra.com>'],
    ['Premium Thailand Packages starting at ₹37,000*.', 'MMT <noreply@zen-makemytrip.com>'],
    ['Regarding Your Recent Hostel Search...', 'Goibibo <hotels@update.goibibo.com>'],
    ['We just got you ₹75 off on movie tickets 🤩', 'BMS <no-reply@info.bookmyshow.com>'],
  ])('rejects %s', (subject, from) => {
    expect(detectMarketingReceipt(from, subject).isMarketing).toBe(true);
  });
});

describe('detectMarketingReceipt — sender local part', () => {
  it('rejects the feedback address but keeps the ticket address on the same domain', () => {
    expect(
      detectMarketingReceipt('Feedback redBus <no_reply_feedback@redbus.in>', 'How was your travel?')
        .reason,
    ).toBe('non_transactional_sender');
    expect(detectMarketingReceipt('redBus <no-reply@redbus.in>', 'redBus Ticket - TV1').isMarketing).toBe(
      false,
    );
  });

  it.each([
    'Customer Research <research@myntra.com>',
    'Myntra <otp@myntra.com>',
    'AWS <aws-india-marketing@amazon.com>',
    'Airbnb <discover@airbnb.com>',
  ])('rejects %s regardless of subject', (from) => {
    expect(detectMarketingReceipt(from, 'Anything at all').isMarketing).toBe(true);
  });

  it('does not treat a bare no-reply as non-transactional', () => {
    expect(detectMarketingReceipt('X <no-reply@swiggy.in>', 'Your order arrived').isMarketing).toBe(false);
  });

  it('handles a null sender', () => {
    expect(detectMarketingReceipt(null, 'Your Swiggy order was delivered').isMarketing).toBe(false);
  });
});

describe('normalizeSubject', () => {
  // The HDFC lesson: subjects carry U+00A0 and friends, so a pattern with a
  // literal space fails against text that looks identical in a terminal.
  it('collapses non-breaking and zero-width whitespace', () => {
    expect(normalizeSubject('Sale is LIVE​')).toBe('Sale is LIVE');
  });

  it('matches a marketing pattern written with plain spaces across NBSPs', () => {
    expect(
      detectMarketingReceipt('Myntra <updates@myntra.com>', 'Clearance Sale Is LIVE 🛒')
        .isMarketing,
    ).toBe(true);
  });
});
