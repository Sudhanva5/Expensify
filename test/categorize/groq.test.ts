import { describe, it, expect } from 'vitest';
import {
  buildGroqPrompt,
  parseGroqResponse,
  HttpGroqCategorizer,
} from '../../src/categorize/groq.js';
import { istDate } from '../_helpers/makeTx.js';

describe('buildGroqPrompt', () => {
  it('includes all 7 categories', () => {
    const p = buildGroqPrompt({
      merchantRaw: 'X',
      merchantNormalized: 'X',
      vpa: null,
      amountInr: 100,
      occurredAt: new Date(),
      direction: 'out',
      instrument: 'account_5264',
      isAutopay: false,
    });
    expect(p).toContain('- Travel');
    expect(p).toContain('- Food');
    expect(p).toContain('- Subscriptions');
    expect(p).toContain('- Personal Transfer (Peer-to-Peer)');
    expect(p).toContain('- Groceries / Kirana Stores');
  });

  it('renders the IST timestamp readably', () => {
    const p = buildGroqPrompt({
      merchantRaw: 'X',
      merchantNormalized: 'X',
      vpa: null,
      amountInr: 100,
      occurredAt: istDate(2026, 5, 4, 8, 42), // Mon 08:42 IST
      direction: 'out',
      instrument: 'account_5264',
      isAutopay: false,
    });
    expect(p).toContain('Mon 2026-05-04 08:42 IST');
  });

  it('shows "none" when vpa is null', () => {
    const p = buildGroqPrompt({
      merchantRaw: 'X',
      merchantNormalized: 'X',
      vpa: null,
      amountInr: 100,
      occurredAt: new Date(),
      direction: 'out',
      instrument: 'card_3328',
      isAutopay: false,
    });
    expect(p).toContain('UPI VPA: none');
  });

  it('quotes vpa when present', () => {
    const p = buildGroqPrompt({
      merchantRaw: 'X',
      merchantNormalized: 'X',
      vpa: 'q201985284@ybl',
      amountInr: 100,
      occurredAt: new Date(),
      direction: 'out',
      instrument: 'account_5264',
      isAutopay: false,
    });
    expect(p).toContain('UPI VPA: "q201985284@ybl"');
  });

  it('renders webContext when supplied (Tier-4 grounding)', () => {
    const p = buildGroqPrompt({
      merchantRaw: 'X',
      merchantNormalized: 'X',
      vpa: null,
      amountInr: 100,
      occurredAt: new Date(),
      direction: 'out',
      instrument: 'account_5264',
      isAutopay: false,
      webContext: [
        { title: 'A kirana shop', snippet: 'in Jayanagar', url: 'https://x' },
      ],
    });
    expect(p).toContain('Web search results');
    expect(p).toContain('A kirana shop');
    expect(p).toContain('in Jayanagar');
  });

  it('omits the web section when webContext is empty', () => {
    const p = buildGroqPrompt({
      merchantRaw: 'X',
      merchantNormalized: 'X',
      vpa: null,
      amountInr: 100,
      occurredAt: new Date(),
      direction: 'out',
      instrument: 'account_5264',
      isAutopay: false,
      webContext: [],
    });
    expect(p).not.toContain('Web search results');
  });
});

describe('parseGroqResponse', () => {
  it('parses a well-formed response', () => {
    const r = parseGroqResponse(
      JSON.stringify({
        category: 'Food',
        confidence: 0.91,
        rationale: 'Swiggy variant',
      }),
    );
    expect(r.category).toBe('Food');
    expect(r.confidence).toBe(0.91);
  });

  it('accepts null category', () => {
    const r = parseGroqResponse(
      JSON.stringify({
        category: null,
        confidence: 0,
        rationale: 'unsure',
      }),
    );
    expect(r.category).toBeNull();
  });

  it('returns safe fallback on invalid JSON', () => {
    const r = parseGroqResponse('not json {');
    expect(r.category).toBeNull();
    expect(r.confidence).toBe(0);
    expect(r.rationale).toContain('invalid JSON');
  });

  it('returns safe fallback on schema mismatch (unknown category)', () => {
    const r = parseGroqResponse(
      JSON.stringify({
        category: 'Bananas',
        confidence: 0.9,
        rationale: 'x',
      }),
    );
    expect(r.category).toBeNull();
  });

  it('returns safe fallback on out-of-range confidence', () => {
    const r = parseGroqResponse(
      JSON.stringify({
        category: 'Food',
        confidence: 1.5,
        rationale: 'x',
      }),
    );
    expect(r.category).toBeNull();
  });
});

describe('HttpGroqCategorizer', () => {
  it('sends a POST with the right shape and parses the response', async () => {
    const fetchSpy = async (_url: string | URL | Request, init?: RequestInit) => {
      // Verify request shape
      expect(init?.method).toBe('POST');
      const headers = init?.headers as Record<string, string>;
      expect(headers['Authorization']).toBe('Bearer test-key');
      expect(headers['Content-Type']).toBe('application/json');
      const body = JSON.parse(String(init?.body));
      expect(body.model).toBe('llama-3.1-8b-instant');
      expect(body.response_format).toEqual({ type: 'json_object' });
      expect(body.messages[0].role).toBe('user');

      return new Response(
        JSON.stringify({
          choices: [
            {
              message: {
                content: JSON.stringify({
                  category: 'Food',
                  confidence: 0.93,
                  rationale: 'Swiggy alias',
                }),
              },
            },
          ],
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    };

    const client = new HttpGroqCategorizer({
      apiKey: 'test-key',
      fetchFn: fetchSpy as typeof fetch,
    });

    const out = await client.categorize({
      merchantRaw: 'BUNDL TECHNOLOGIES',
      merchantNormalized: 'BUNDL TECHNOLOGIES',
      vpa: null,
      amountInr: 547,
      occurredAt: new Date(),
      direction: 'out',
      instrument: 'card_3328',
      isAutopay: false,
    });

    expect(out.category).toBe('Food');
    expect(out.confidence).toBeCloseTo(0.93);
  });

  it('throws on non-2xx response', async () => {
    const fetchFn = async () =>
      new Response('rate limited', { status: 429 });
    const client = new HttpGroqCategorizer({
      apiKey: 'k',
      fetchFn: fetchFn as typeof fetch,
    });

    await expect(
      client.categorize({
        merchantRaw: 'X',
        merchantNormalized: 'X',
        vpa: null,
        amountInr: 100,
        occurredAt: new Date(),
        direction: 'out',
        instrument: 'card_3328',
        isAutopay: false,
      }),
    ).rejects.toThrow(/429/);
  });

  it('returns safe fallback on empty response content', async () => {
    const fetchFn = async () =>
      new Response(JSON.stringify({ choices: [{ message: {} }] }), {
        status: 200,
      });
    const client = new HttpGroqCategorizer({
      apiKey: 'k',
      fetchFn: fetchFn as typeof fetch,
    });

    const out = await client.categorize({
      merchantRaw: 'X',
      merchantNormalized: 'X',
      vpa: null,
      amountInr: 100,
      occurredAt: new Date(),
      direction: 'out',
      instrument: 'card_3328',
      isAutopay: false,
    });
    expect(out.category).toBeNull();
  });
});
