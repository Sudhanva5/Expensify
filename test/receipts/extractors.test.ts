import { describe, it, expect } from 'vitest';
import {
  extractUniversal,
  extractSwiggy,
  pickExtractor,
  isReceiptSender,
} from '../../src/receipts/extractors.js';

describe('extractUniversal', () => {
  it('pulls the largest ₹ amount as the total', () => {
    const text = `
      Item ₹185
      Restaurant Packaging ₹10
      Platform fee ₹17.58
      Delivery Fee ₹73
      Taxes ₹22.89
      Paid Via Bank ₹308.00
    `;
    const r = extractUniversal(text);
    // Largest is 308.00
    expect(r.amountInrMinor).toBe(30800n);
  });

  it('handles Indian-formatted thousands', () => {
    const text = 'Total: ₹1,23,456.78';
    const r = extractUniversal(text);
    expect(r.amountInrMinor).toBe(12345678n);
  });

  it('accepts Rs. and INR prefixes', () => {
    expect(extractUniversal('Total Rs.500').amountInrMinor).toBe(50000n);
    expect(extractUniversal('Total INR 250').amountInrMinor).toBe(25000n);
  });

  it('captures Order ID', () => {
    expect(extractUniversal('Order ID: 237743205871052').orderId).toBe('237743205871052');
    expect(extractUniversal('Order No 112-7892').orderId).toBe('112-7892');
    expect(extractUniversal('Order #ABC12345').orderId).toBe('ABC12345');
  });

  it('returns null amount/orderId for unrelated text', () => {
    const r = extractUniversal('Hello world, this email has no order info');
    expect(r.amountInrMinor).toBeNull();
    expect(r.orderId).toBeNull();
  });
});

describe('extractSwiggy', () => {
  // A trimmed-down but realistic Swiggy receipt body (stripped HTML)
  const swiggyBody = `
    Delivery in 30 mins! ₹71 saved on this order
    ORDER JOURNEY
    California Burrito Shop No : NO. 65/3/1 , DODDAKANNALLI , May 14, 9:57 PM
    Sudhanva Acharya 402 Renuka Yellamma Nilaya, Bengaluru May 14, 10:27 PM
    Order ID: 237745656192462
    BILL DETAILS
    Hot Habanero Burrito - Paneer x1 ₹169
    Restaurant Packaging ₹15.00
    Platform fee with GST ₹17.58
    Delivery Fee (FREE with One BLCK) ₹91 FREE
    Taxes ₹9.20
    Paid Via Bank ₹211.00
  `;

  it('extracts total from "Paid Via Bank"', () => {
    const r = extractSwiggy(swiggyBody);
    expect(r).not.toBeNull();
    expect(r!.amountInrMinor).toBe(21100n);
  });

  it('extracts order id', () => {
    const r = extractSwiggy(swiggyBody);
    expect(r!.orderId).toBe('237745656192462');
  });

  it('extracts items with quantity and price', () => {
    const r = extractSwiggy(swiggyBody);
    expect(r!.items).toHaveLength(1);
    expect(r!.items![0]).toEqual({
      name: 'Hot Habanero Burrito - Paneer',
      qty: 1,
      priceInr: 169,
    });
  });

  it('extracts fees as fee lines, not item lines', () => {
    const r = extractSwiggy(swiggyBody);
    expect(r!.fees!.map((f) => f.name)).toContain('Restaurant Packaging');
    expect(r!.fees!.map((f) => f.name)).toContain('Platform fee with GST');
    expect(r!.fees!.find((f) => f.name === 'Restaurant Packaging')?.amountInr).toBe(15);
  });

  it('extracts journey from / to entries', () => {
    const r = extractSwiggy(swiggyBody);
    const meta = r!.meta as { journeyFrom?: { text: string; timestamp: string } };
    expect(meta.journeyFrom?.text).toContain('California Burrito');
    expect(meta.journeyFrom?.timestamp).toContain('May 14');
  });

  it('returns null for unrelated email body', () => {
    const r = extractSwiggy('A regular non-receipt email body with no section markers.');
    expect(r).toBeNull();
  });

  it('returns null for marketing-only Swiggy email (no bill details)', () => {
    const r = extractSwiggy('Get 20% off your next order! ORDER JOURNEY...');
    expect(r).toBeNull();
  });
});

describe('pickExtractor', () => {
  it('routes Swiggy address to swiggy source', () => {
    expect(pickExtractor('noreply-orders@swiggy.in').source).toBe('swiggy');
  });

  it('routes Amazon to amazon source', () => {
    expect(pickExtractor('auto-confirm@amazon.in').source).toBe('amazon');
  });

  it('routes unknown sender to generic', () => {
    expect(pickExtractor('hi@randomsite.com').source).toBe('generic');
  });
});

describe('isReceiptSender', () => {
  it('recognizes known receipt domains', () => {
    expect(isReceiptSender('noreply@swiggy.in')).toBe(true);
    expect(isReceiptSender('orders@zomato.com')).toBe(true);
    expect(isReceiptSender('auto@bookmyshow.com')).toBe(true);
  });

  it('rejects unknown senders', () => {
    expect(isReceiptSender('hi@randomsite.com')).toBe(false);
    expect(isReceiptSender(null)).toBe(false);
  });
});
