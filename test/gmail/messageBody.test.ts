import { describe, it, expect } from 'vitest';
import {
  extractMessage,
  decodeBase64Url,
  stripHtml,
  isLikelyHdfcAlert,
} from '../../src/gmail/messageBody.js';

const b64u = (s: string) =>
  Buffer.from(s, 'utf-8').toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

describe('decodeBase64Url', () => {
  it('decodes base64url back to utf-8', () => {
    expect(decodeBase64Url(b64u('Rs.547.00 debited'))).toBe('Rs.547.00 debited');
  });

  it('handles strings without padding', () => {
    expect(decodeBase64Url(b64u('hi'))).toBe('hi');
  });

  it('handles + and / characters via the url variant', () => {
    // `?` is encoded as Pw==; in base64url that's "Pw" (no padding, no special chars)
    expect(decodeBase64Url('Pw')).toBe('?');
  });
});

describe('stripHtml', () => {
  it('removes tags and collapses whitespace', () => {
    expect(stripHtml('<p>Hello <b>world</b></p>')).toBe('Hello world');
  });

  it('decodes common HTML entities', () => {
    // Order: tags-then-entities-then-whitespace-collapse, so the &nbsp;-derived
    // double space gets collapsed to a single space.
    expect(stripHtml('&amp; &lt;tag&gt; &nbsp;done')).toBe('& <tag> done');
  });

  it('drops script and style blocks entirely', () => {
    expect(stripHtml('A<script>alert(1)</script>B')).toBe('A B');
    expect(stripHtml('A<style>.x{}</style>B')).toBe('A B');
  });

  it('renders <br> as a newline', () => {
    expect(stripHtml('one<br>two<br/>three')).toContain('\n');
  });
});

describe('extractMessage — text/plain body', () => {
  it('pulls subject, from, snippet, body, receivedAt', () => {
    const msg = {
      id: 'gmail-id-1',
      internalDate: String(new Date('2026-05-09T10:57:54Z').getTime()),
      snippet: 'Rs. 547.00 debited',
      payload: {
        headers: [
          { name: 'Subject', value: 'You have done a transaction' },
          { name: 'From', value: 'HDFC Bank <alerts@hdfcbank.net>' },
        ],
        mimeType: 'text/plain',
        body: { data: b64u('Rs. 547.00 has been debited from your HDFC Bank Credit Card') },
      },
    };

    const out = extractMessage(msg);
    expect(out.id).toBe('gmail-id-1');
    expect(out.subject).toBe('You have done a transaction');
    expect(out.fromAddress).toBe('HDFC Bank <alerts@hdfcbank.net>');
    expect(out.snippet).toBe('Rs. 547.00 debited');
    expect(out.body).toContain('Rs. 547.00');
    expect(out.receivedAt.getUTCFullYear()).toBe(2026);
  });
});

describe('extractMessage — multipart with HTML fallback', () => {
  it('prefers text/plain over text/html when both present', () => {
    const msg = {
      id: 'gmail-id-2',
      internalDate: '0',
      payload: {
        headers: [{ name: 'Subject', value: 'X' }],
        mimeType: 'multipart/alternative',
        parts: [
          {
            mimeType: 'text/plain',
            body: { data: b64u('plain version') },
          },
          {
            mimeType: 'text/html',
            body: { data: b64u('<p>html version</p>') },
          },
        ],
      },
    };
    expect(extractMessage(msg).body).toBe('plain version');
  });

  it('falls back to text/html, stripped, when no plain part', () => {
    const msg = {
      id: 'gmail-id-3',
      internalDate: '0',
      payload: {
        headers: [{ name: 'Subject', value: 'X' }],
        mimeType: 'multipart/related',
        parts: [
          {
            mimeType: 'text/html',
            body: {
              data: b64u(
                '<html><body><p>Rs. 211.00 debited towards <b>RAZ*Swiggy</b></p></body></html>',
              ),
            },
          },
        ],
      },
    };
    const out = extractMessage(msg);
    expect(out.body).toContain('Rs. 211.00 debited towards');
    expect(out.body).toContain('RAZ*Swiggy');
    expect(out.body).not.toContain('<');
  });

  it('descends into nested multipart trees', () => {
    const msg = {
      id: 'gmail-id-4',
      internalDate: '0',
      payload: {
        headers: [],
        mimeType: 'multipart/mixed',
        parts: [
          {
            mimeType: 'multipart/alternative',
            parts: [
              {
                mimeType: 'text/plain',
                body: { data: b64u('found me') },
              },
            ],
          },
        ],
      },
    };
    expect(extractMessage(msg).body).toBe('found me');
  });
});

describe('isLikelyHdfcAlert', () => {
  it('matches alerts@hdfcbank.net', () => {
    expect(isLikelyHdfcAlert('HDFC Bank <alerts@hdfcbank.net>')).toBe(true);
  });

  it('matches noreply variant', () => {
    expect(isLikelyHdfcAlert('noreply.alerts@hdfcbank.net')).toBe(true);
  });

  it('matches when display name contains HDFC Bank', () => {
    expect(isLikelyHdfcAlert('HDFC Bank <something@example.com>')).toBe(true);
  });

  it('rejects unrelated senders', () => {
    expect(isLikelyHdfcAlert('promo@swiggy.in')).toBe(false);
    expect(isLikelyHdfcAlert(null)).toBe(false);
  });
});

const SENDER = 'HDFC Bank InstaAlerts <alerts@hdfcbank.bank.in>';

// Every one of these was observed leaking past the subject blacklist into
// the parser chain, where it failed and fired a "parser missed an email"
// push. None of them is a transaction.
describe('isLikelyHdfcAlert — marketing / servicing subjects are rejected', () => {
  const REJECTED = [
    // Statements and investor relations
    'Your HDFC Bank - Regalia Gold Credit Card Statement - July-2026',
    'HDFC Bank Combined Email Statement for June-2026',
    'HDFC Bank Limited - Consolidated and Standalone Unaudited Financial Results for the quarter ended June 30, 2026',
    // Service notices
    '⚠️ Scheduled Downtime Alert for All-New HDFC Bank App and NetBanking on 11th and 19th July 2026.',
    // Real subject as HDFC sent it. The gap between "Scheduled" and
    // "Downtime" is a non-breaking space (U+00A0), not an ASCII space —
    // copied verbatim from the wire. /\bscheduled downtime\b/ cannot match
    // it, which is how this mailer kept slipping through; isLikelyHdfcAlert
    // normalizes whitespace first. Keep the U+00A0 if you edit this line.
    '⚠️ Scheduled Downtime Alert for HDFC Bank UPI services on 23rd May 2026',
    'Missed Call from your HDFC Bank Relationship Manager - Ashwini T V',
    'Important Update on your HDFC Bank Card x3328 💳',
    'Credit Card xx3328: Important Card Update',
    '🛡️Important Security Update - Now Live: Transfer Limits for New Beneficiaries',
    '🔍 Customer, noticed a change in your NetBanking view?',
    '📢 Dear Customer, your DigiPassBook has evolved',
    'One app for card limits, transactions & more>>',
    '💳 Customer, Experience MyCards on PayZapp 📲',
    '📊 Dear Customer, all your balances and investments, now easier to see',
    'Hi S M Sudhanva Acharya, Happy Birthday!',
    'OTP For online Ecom Transaction',
    // Credit-card upsells
    'Credit Card xx3803: View Updated Rate on SmartEMI',
    'Credit Card xx3328: Processing Fee Update',
    'Credit Card xx3328: Processing Fee Details Updated',
    'Card No. xx3803, check our next best Offering for you',
    // Loan / insurance / investment pitches
    '🎉Get upto Rs.7.5 Lacs at a lowered rate ⏬',
    'Congrats, 🎉 Avail Rs.15 Lacs at Lowest Rate based on your Good Credit',
    '🏡 Customer, Take the Next Step to Your Own Home',
    ' 🔑 Customer, Find Your Dream Home Today! 🏠',
    "Customer, Instant Funds Ready! Don't Miss Out >>",
    'A/c xx5264: Instant Funds for Your Summer Trip',
    'Customer, your finances deserve a stronger safety net',
    'Your loved ones rely on your financial strength',
    'Dear Customer, Last Chance to Get 4X Coverage at No Extra Cost',
    'A/C No.xxxx5264, Your protection-upgraded with ReAssure 3.0.',
    // Fraud-awareness campaigns
    'Digital arrest is 100% fake',
    '🚨 AI Deepfake fraud alert - verify before you trust',
    '⚠️ Tax Season Alert: Stay Safe from Tax Fraud',
    'Dear Customer, Filing Your ITR? Pay Self-Assessment Tax',
    // Shopping / travel offers
    'Customer, add to cart. add to savings 🛍️',
    '🛍️ Customer, Myntra EORS is live with 10% off',
    'Customer, 🎟️ Cleartrip savings are waiting for you 🧳',
    '✈️ Customer, travel globally with ZERO markup fees',
  ];

  for (const subject of REJECTED) {
    it(`rejects: ${subject.slice(0, 60)}`, () => {
      expect(isLikelyHdfcAlert(SENDER, subject)).toBe(false);
    });
  }
});

// The blacklist is subject-only and runs before every parser, so a
// false positive here silently drops real money. These are the actual
// subjects of transaction and balance alerts we depend on.
describe('isLikelyHdfcAlert — real alert subjects still pass', () => {
  const ACCEPTED = [
    '❗  You have done a UPI txn. Check details!',
    'We noticed a transaction on your Credit Card',
    // Carries BOTH the account balance alert and the debit-card ATM
    // withdrawal alert — never blacklist it.
    'View: Account update for your HDFC Bank A/c',
    'Alert: You have used your HDFC Bank Card',
    'Transaction Alert',
    'You have received money',
    'Update on your HDFC Bank Credit Card autopay',
    '',
  ];

  for (const subject of ACCEPTED) {
    it(`accepts: ${subject || '(empty subject)'}`, () => {
      expect(isLikelyHdfcAlert(SENDER, subject)).toBe(true);
    });
  }
});
