// Tier 4 helper — Brave Search client, used to ground Groq with web snippets
// when an unknown merchant can't be categorized from the transaction alone.

export interface BraveSearchResult {
  title: string;
  snippet: string;
  url: string;
}

export interface BraveSearchInput {
  merchant: string;
  city?: string;
}

export interface BraveSearchClient {
  search(input: BraveSearchInput): Promise<BraveSearchResult[]>;
}

export function buildBraveQuery(input: BraveSearchInput): string {
  const parts = [`"${input.merchant}"`];
  if (input.city) parts.push(input.city);
  else parts.push('India');
  return parts.join(' ');
}

function stripHtml(s: string): string {
  return s.replace(/<[^>]*>/g, '');
}

export interface HttpBraveOptions {
  apiKey: string;
  fetchFn?: typeof fetch;
  count?: number; // results to fetch (default 5)
}

export class HttpBraveSearchClient implements BraveSearchClient {
  private readonly apiKey: string;
  private readonly fetchFn: typeof fetch;
  private readonly count: number;

  constructor(opts: HttpBraveOptions) {
    this.apiKey = opts.apiKey;
    this.fetchFn = opts.fetchFn ?? fetch;
    this.count = opts.count ?? 5;
  }

  async search(input: BraveSearchInput): Promise<BraveSearchResult[]> {
    const query = buildBraveQuery(input);
    const url = `https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(query)}&count=${this.count}`;

    const res = await this.fetchFn(url, {
      headers: {
        'X-Subscription-Token': this.apiKey,
        Accept: 'application/json',
      },
    });

    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new Error(`Brave API error ${res.status}: ${body}`);
    }

    const data = (await res.json()) as {
      web?: {
        results?: { title?: string; description?: string; url?: string }[];
      };
    };

    const results = data.web?.results ?? [];
    return results
      .filter((r) => r.title && r.description && r.url)
      .slice(0, this.count)
      .map((r) => ({
        title: stripHtml(r.title!),
        snippet: stripHtml(r.description!),
        url: r.url!,
      }));
  }
}
