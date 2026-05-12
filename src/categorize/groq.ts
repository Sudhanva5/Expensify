// Tier 3 — Groq categorization. Defined as an interface so it can be mocked
// in tests; the HTTP implementation is supplied at runtime.

import { z } from 'zod';
import { CATEGORIES, type CategoryName } from './types.js';
import type { BraveSearchResult } from './brave.js';
import type { NearbyPlace } from '../services/places.js';

const IST_OFFSET_MS = (5 * 60 + 30) * 60 * 1000;

export interface GroqCategorizeInput {
  merchantRaw: string;
  merchantNormalized: string;
  vpa: string | null;
  amountInr: number; // major units (rupees)
  occurredAt: Date;
  direction: 'in' | 'out';
  instrument: string;
  isAutopay: boolean;
  // Optional Tier-4 grounding: web search results about the merchant.
  webContext?: BraveSearchResult[];
  // Optional Places-tier grounding: businesses near the transaction location.
  // When supplied, Groq picks the most likely candidate AND returns its name
  // so we can update merchantNormalized.
  placesContext?: NearbyPlace[];
}

export interface GroqCategorizeOutput {
  category: CategoryName | null;
  confidence: number;
  rationale: string;
  /// Resolved business name (from Places candidates) — only present when
  /// placesContext was supplied and Groq picked a specific candidate.
  merchantName?: string;
}

export interface GroqCategorizer {
  categorize(input: GroqCategorizeInput): Promise<GroqCategorizeOutput>;
}

// === Prompt builder ===

export function buildGroqPrompt(input: GroqCategorizeInput): string {
  const ist = new Date(input.occurredAt.getTime() + IST_OFFSET_MS);
  const dayName = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][ist.getUTCDay()];
  const date = `${ist.getUTCFullYear()}-${pad(ist.getUTCMonth() + 1)}-${pad(ist.getUTCDate())}`;
  const time = `${pad(ist.getUTCHours())}:${pad(ist.getUTCMinutes())}`;

  const webSection =
    input.webContext && input.webContext.length > 0
      ? `\nWeb search results about this merchant (use these to identify what kind of business it is):
${input.webContext
  .map((r, i) => `${i + 1}. ${r.title}\n   ${r.snippet}`)
  .join('\n')}\n`
      : '';

  const placesSection =
    input.placesContext && input.placesContext.length > 0
      ? `\nBusinesses within 100m of the transaction location (pick the most likely one — or say it's none of these if the user was paying a friend/driver who happened to be at this spot):
${input.placesContext
  .map(
    (p, i) =>
      `${i + 1}. ${p.name} — types: ${p.types.slice(0, 4).join(', ')}${
        p.formattedAddress ? ` — ${p.formattedAddress}` : ''
      }`,
  )
  .join('\n')}
If one of these places clearly matches what the user just paid for, return its exact "name" string in the "merchantName" field of your JSON response.\n`
      : '';

  return `You are a transaction categorizer for an Indian personal finance app.

Categorize this transaction into exactly ONE of these categories, or null if you cannot reasonably categorize:
${CATEGORIES.map((c) => `- ${c}`).join('\n')}

Transaction:
- Merchant (raw): "${input.merchantRaw}"
- Merchant (cleaned): "${input.merchantNormalized}"
- UPI VPA: ${input.vpa ? `"${input.vpa}"` : 'none'}
- Amount: ₹${input.amountInr.toFixed(2)}
- When: ${dayName} ${date} ${time} IST
- Direction: ${input.direction === 'out' ? 'outgoing spend' : 'incoming credit'}
- Instrument: ${input.instrument}
- Auto-pay: ${input.isAutopay ? 'yes' : 'no'}
${placesSection}${webSection}
Indian context hints:
- Personal UPI handles: @oksbi, @okaxis, @okhdfcbank, @okicici. Local-part shaped like a person's name = Personal Transfer.
- Merchant UPI handles: @ybl with q-prefix usually means a small business.
- Suffixes like "ENTERPRISES", "STORES", "TRADERS", "AGENCIES", "MART", "GENERAL STORES" typically indicate retail/grocery shops.
- BUNDL TECHNOLOGIES = Swiggy; ANI TECHNOLOGIES = Ola; ZERODHA / GROWW = Investments; IRCTC = Travel.

Respond with JSON only — no markdown, no preamble:
{
  "category": "<exact category name from the list, or null>",
  "confidence": <number between 0 and 1>,
  "rationale": "<one short sentence>",
  "merchantName": "<exact name of the matched nearby business, or omit if none matches>"
}`;
}

function pad(n: number): string {
  return String(n).padStart(2, '0');
}

// === Response validation ===

export const groqResponseSchema = z.object({
  category: z.union([z.enum(CATEGORIES), z.null()]),
  confidence: z.number().min(0).max(1),
  rationale: z.string().max(500),
  merchantName: z.string().min(1).max(200).optional(),
});

// Lenient parse: returns a safe "no signal" output on validation failure
// rather than throwing, so a bad LLM response degrades gracefully.
export function parseGroqResponse(content: string): GroqCategorizeOutput {
  let json: unknown;
  try {
    json = JSON.parse(content);
  } catch {
    return { category: null, confidence: 0, rationale: 'invalid JSON from model' };
  }
  const parsed = groqResponseSchema.safeParse(json);
  if (!parsed.success) {
    return { category: null, confidence: 0, rationale: 'response did not match schema' };
  }
  return parsed.data;
}

// === HTTP implementation ===

export interface HttpGroqOptions {
  apiKey: string;
  model?: string;
  fetchFn?: typeof fetch;
}

export class HttpGroqCategorizer implements GroqCategorizer {
  private readonly apiKey: string;
  private readonly model: string;
  private readonly fetchFn: typeof fetch;

  constructor(opts: HttpGroqOptions) {
    this.apiKey = opts.apiKey;
    this.model = opts.model ?? 'llama-3.1-8b-instant';
    this.fetchFn = opts.fetchFn ?? fetch;
  }

  async categorize(input: GroqCategorizeInput): Promise<GroqCategorizeOutput> {
    const prompt = buildGroqPrompt(input);
    const res = await this.fetchFn('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: this.model,
        messages: [{ role: 'user', content: prompt }],
        response_format: { type: 'json_object' },
        temperature: 0.2,
        max_tokens: 200,
      }),
    });

    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new Error(`Groq API error ${res.status}: ${body}`);
    }

    const data = (await res.json()) as {
      choices?: { message?: { content?: string } }[];
    };
    const content = data.choices?.[0]?.message?.content;
    if (!content) {
      return { category: null, confidence: 0, rationale: 'empty response from model' };
    }

    return parseGroqResponse(content);
  }
}
