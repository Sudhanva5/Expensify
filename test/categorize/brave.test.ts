import { describe, it, expect } from 'vitest';
import {
  buildBraveQuery,
  HttpBraveSearchClient,
} from '../../src/categorize/brave.js';

describe('buildBraveQuery', () => {
  it('quotes the merchant and includes city when present', () => {
    expect(
      buildBraveQuery({
        merchant: 'SRI GURU RAGHAVENDRA ENTERPRISES',
        city: 'Bangalore',
      }),
    ).toBe('"SRI GURU RAGHAVENDRA ENTERPRISES" Bangalore');
  });

  it('falls back to "India" when no city', () => {
    expect(buildBraveQuery({ merchant: 'TEST CORP' })).toBe(
      '"TEST CORP" India',
    );
  });
});

describe('HttpBraveSearchClient', () => {
  it('sends auth header and parses results, stripping HTML', async () => {
    const fetchSpy = async (url: string | URL | Request, init?: RequestInit) => {
      const u = String(url);
      expect(u).toContain('api.search.brave.com');
      expect(u).toContain('q=');
      const headers = init?.headers as Record<string, string>;
      expect(headers['X-Subscription-Token']).toBe('brave-key');

      return new Response(
        JSON.stringify({
          web: {
            results: [
              {
                title: 'Sri Guru <strong>Raghavendra</strong> Enterprises',
                description: 'A <strong>kirana</strong> store in Jayanagar, Bangalore.',
                url: 'https://example.com/1',
              },
              {
                title: 'JustDial listing',
                description: 'Grocery shop near 4th block',
                url: 'https://example.com/2',
              },
            ],
          },
        }),
        { status: 200 },
      );
    };

    const client = new HttpBraveSearchClient({
      apiKey: 'brave-key',
      fetchFn: fetchSpy as typeof fetch,
    });

    const results = await client.search({
      merchant: 'SRI GURU RAGHAVENDRA ENTERPRISES',
      city: 'Bangalore',
    });

    expect(results).toHaveLength(2);
    expect(results[0]!.title).toBe('Sri Guru Raghavendra Enterprises'); // HTML stripped
    expect(results[0]!.snippet).toBe('A kirana store in Jayanagar, Bangalore.');
    expect(results[0]!.url).toBe('https://example.com/1');
  });

  it('returns [] when API returns no web.results', async () => {
    const fetchFn = async () =>
      new Response(JSON.stringify({}), { status: 200 });
    const client = new HttpBraveSearchClient({
      apiKey: 'k',
      fetchFn: fetchFn as typeof fetch,
    });
    expect(await client.search({ merchant: 'X' })).toEqual([]);
  });

  it('throws on non-2xx', async () => {
    const fetchFn = async () =>
      new Response('rate limited', { status: 429 });
    const client = new HttpBraveSearchClient({
      apiKey: 'k',
      fetchFn: fetchFn as typeof fetch,
    });
    await expect(client.search({ merchant: 'X' })).rejects.toThrow(/429/);
  });

  it('drops results missing required fields', async () => {
    const fetchFn = async () =>
      new Response(
        JSON.stringify({
          web: {
            results: [
              { title: 'A', description: 'desc', url: 'u' },
              { title: 'B' }, // incomplete — drop
              { description: 'C', url: 'u' }, // incomplete — drop
            ],
          },
        }),
        { status: 200 },
      );
    const client = new HttpBraveSearchClient({
      apiKey: 'k',
      fetchFn: fetchFn as typeof fetch,
    });
    const results = await client.search({ merchant: 'X' });
    expect(results).toHaveLength(1);
    expect(results[0]!.title).toBe('A');
  });
});
