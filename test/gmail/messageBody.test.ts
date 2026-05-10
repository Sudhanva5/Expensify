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
