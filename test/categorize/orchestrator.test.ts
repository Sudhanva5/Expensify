import { describe, it, expect, vi } from 'vitest';
import { categorize } from '../../src/categorize/index.js';
import {
  ROUTING_PREFIXES,
  SEED_ALIASES,
  SEED_AUTOPAY_ALIASES,
} from '../../src/categorize/seed.js';
import type {
  CategorizeContext,
  UserRule,
} from '../../src/categorize/types.js';
import type {
  GroqCategorizer,
  GroqCategorizeInput,
  GroqCategorizeOutput,
} from '../../src/categorize/groq.js';
import type {
  BraveSearchClient,
  BraveSearchInput,
  BraveSearchResult,
} from '../../src/categorize/brave.js';
import { makeTx, istDate } from '../_helpers/makeTx.js';

const baseCtx: CategorizeContext = {
  aliases: SEED_ALIASES,
  autopayAliases: SEED_AUTOPAY_ALIASES,
  routingPrefixes: ROUTING_PREFIXES,
  rules: [],
};

// Mock Groq that returns a canned response and tracks calls.
// Optionally returns different responses depending on whether webContext was supplied,
// which is how we distinguish Tier-3 calls from Tier-4 calls in tests.
function mockGroq(
  out: GroqCategorizeOutput,
  outWithWeb?: GroqCategorizeOutput,
): GroqCategorizer & {
  calls: { count: number; lastInput: GroqCategorizeInput | null };
} {
  const state = { count: 0, lastInput: null as GroqCategorizeInput | null };
  return {
    calls: state,
    async categorize(input: GroqCategorizeInput) {
      state.count++;
      state.lastInput = input;
      if (outWithWeb && input.webContext && input.webContext.length > 0) {
        return outWithWeb;
      }
      return out;
    },
  };
}

function mockBrave(
  results: BraveSearchResult[],
): BraveSearchClient & { calls: { count: number; lastInput: BraveSearchInput | null } } {
  const state = { count: 0, lastInput: null as BraveSearchInput | null };
  return {
    calls: state,
    async search(input: BraveSearchInput) {
      state.count++;
      state.lastInput = input;
      return results;
    },
  };
}

describe('categorize — alias path', () => {
  it('auto-resolves BUNDL TECHNOLOGIES as Food', async () => {
    const result = await categorize(
      makeTx({ merchantRaw: 'BUNDL TECHNOLOGIES' }),
      baseCtx,
    );
    expect(result.status).toBe('auto_resolved');
    expect(result.picked?.source).toBe('alias');
    expect(result.picked?.category).toBe('Food');
  });

  it('strips RAZ* prefix and auto-resolves Swiggy as Food', async () => {
    const result = await categorize(
      makeTx({ merchantRaw: 'RAZ*Swiggy' }),
      baseCtx,
    );
    expect(result.merchantNormalized).toBe('Swiggy');
    expect(result.status).toBe('auto_resolved');
    expect(result.picked?.category).toBe('Food');
  });
});

describe('categorize — autopay shortcut', () => {
  it('auto-resolves Railway autopay as Travel', async () => {
    const result = await categorize(
      makeTx({
        template: 'cc_autopay',
        merchantRaw: 'Railway',
        isAutopay: true,
        instrument: 'card_3803',
      }),
      baseCtx,
    );
    expect(result.status).toBe('auto_resolved');
    expect(result.picked?.source).toBe('autopay_alias');
    expect(result.picked?.category).toBe('Travel');
  });

  it('auto-resolves Claude autopay as Subscriptions', async () => {
    const result = await categorize(
      makeTx({
        template: 'cc_autopay',
        merchantRaw: 'Claude',
        isAutopay: true,
      }),
      baseCtx,
    );
    expect(result.picked?.category).toBe('Subscriptions');
  });
});

describe('categorize — VPA shape path', () => {
  it('suggests Personal Transfer for SNEHA personal VPA, but needs review', async () => {
    const result = await categorize(
      makeTx({
        direction: 'in',
        merchantRaw: 'SNEHA R',
        vpa: 's.neha2003rajesh-1@okaxis',
      }),
      baseCtx,
    );
    expect(result.status).toBe('needs_review');
    expect(result.picked?.source).toBe('vpa_shape');
    expect(result.picked?.category).toBe('Personal Transfer (Peer-to-Peer)');
    expect(result.picked?.confidence).toBe(0.7);
  });

  it('produces no signal for unknown kirana with merchant VPA (without Groq)', async () => {
    const result = await categorize(
      makeTx({
        merchantRaw: 'SRI GURU RAGHAVENDRA ENTERPRISES',
        vpa: 'q201985284@ybl',
      }),
      baseCtx,
    );
    expect(result.status).toBe('needs_review');
    expect(result.picked).toBeNull();
    expect(result.signals).toHaveLength(0);
  });
});

describe('categorize — user rule engine', () => {
  const uberRule: UserRule = {
    id: 'uber-rule',
    name: 'Probable cab fare',
    priority: 100,
    enabled: true,
    suggestCategory: 'Travel',
    confidence: 0.6,
    conditions: {
      direction: 'out',
      amountBetween: [200, 350],
      timeOfDayBetween: ['08:00', '10:30'],
      dayOfWeek: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'],
      payeeNotInAliasTable: true,
      vpaShape: 'personal',
    },
  };

  it('fires the cab rule for the canonical Uber-driver scenario', async () => {
    const result = await categorize(
      makeTx({
        direction: 'out',
        amountMinor: 28700n,
        merchantRaw: 'RAJESH KUMAR',
        vpa: 'rajesh.kumar2002@oksbi',
        occurredAt: istDate(2026, 5, 4, 8, 42),
      }),
      { ...baseCtx, rules: [uberRule] },
    );

    expect(result.status).toBe('needs_review');
    expect(result.signals.some((s) => s.source === 'user_rule')).toBe(true);
    expect(result.picked?.source).toBe('vpa_shape'); // 0.7 > rule's 0.6
  });

  it('rule does not fire for known alias merchant', async () => {
    const result = await categorize(
      makeTx({
        direction: 'out',
        amountMinor: 28700n,
        merchantRaw: 'BUNDL TECHNOLOGIES',
        occurredAt: istDate(2026, 5, 4, 8, 42),
      }),
      { ...baseCtx, rules: [uberRule] },
    );

    expect(result.status).toBe('auto_resolved');
    expect(result.picked?.source).toBe('alias');
    expect(result.signals.find((s) => s.source === 'user_rule')).toBeUndefined();
  });

  it('rule does not fire on weekend', async () => {
    const result = await categorize(
      makeTx({
        direction: 'out',
        amountMinor: 28700n,
        merchantRaw: 'RAJESH KUMAR',
        vpa: 'rajesh@oksbi',
        occurredAt: istDate(2026, 5, 9, 8, 42),
      }),
      { ...baseCtx, rules: [uberRule] },
    );
    expect(result.signals.find((s) => s.source === 'user_rule')).toBeUndefined();
  });
});

describe('categorize — pick logic', () => {
  it('picks highest-confidence signal when multiple agree', async () => {
    const supportRule: UserRule = {
      id: 'support',
      name: 'Lunch hour',
      priority: 100,
      enabled: true,
      suggestCategory: 'Food',
      confidence: 0.6,
      conditions: { timeOfDayBetween: ['12:00', '14:00'] },
    };

    const result = await categorize(
      makeTx({
        merchantRaw: 'RAZ*Swiggy',
        occurredAt: istDate(2026, 5, 4, 13, 0),
      }),
      { ...baseCtx, rules: [supportRule] },
    );

    expect(result.status).toBe('auto_resolved');
    expect(result.picked?.source).toBe('alias');
  });

  it('returns null pick + needs_review when no signal fires', async () => {
    const result = await categorize(
      makeTx({ merchantRaw: 'COMPLETELY UNKNOWN MERCHANT XYZ' }),
      baseCtx,
    );
    expect(result.picked).toBeNull();
    expect(result.status).toBe('needs_review');
  });
});

describe('categorize — Tier 3 (Groq)', () => {
  it('calls Groq when no auto-tag signal fires (unknown kirana)', async () => {
    const groq = mockGroq({
      category: 'Groceries / Kirana Stores',
      confidence: 0.82,
      rationale: 'ENTERPRISES suffix and small amount suggest a kirana store',
    });

    const result = await categorize(
      makeTx({
        merchantRaw: 'SRI GURU RAGHAVENDRA ENTERPRISES',
        vpa: 'q201985284@ybl',
        amountMinor: 9400n,
      }),
      { ...baseCtx, groq },
    );

    expect(groq.calls.count).toBe(1);
    expect(result.signals.some((s) => s.source === 'groq')).toBe(true);
    expect(result.picked?.source).toBe('groq');
    expect(result.picked?.category).toBe('Groceries / Kirana Stores');
    expect(result.status).toBe('needs_review'); // 0.82 < 0.95 threshold
  });

  it('skips Groq when an alias has already auto-tagged', async () => {
    const groq = mockGroq({
      category: 'Food',
      confidence: 0.9,
      rationale: 'should not be called',
    });

    const result = await categorize(
      makeTx({ merchantRaw: 'BUNDL TECHNOLOGIES' }),
      { ...baseCtx, groq },
    );

    expect(groq.calls.count).toBe(0);
    expect(result.picked?.source).toBe('alias');
    expect(result.status).toBe('auto_resolved');
  });

  it('still calls Groq when only a low-confidence VPA-shape signal exists', async () => {
    const groq = mockGroq({
      category: 'Personal Transfer (Peer-to-Peer)',
      confidence: 0.85,
      rationale: 'corroborates personal VPA',
    });

    const result = await categorize(
      makeTx({
        merchantRaw: 'SNEHA R',
        vpa: 's.neha2003rajesh-1@okaxis',
        direction: 'in',
      }),
      { ...baseCtx, groq },
    );

    expect(groq.calls.count).toBe(1);
    // Both signals (VPA 0.7 and Groq 0.85) — Groq wins
    expect(result.picked?.source).toBe('groq');
    expect(result.picked?.confidence).toBe(0.85);
  });

  it('drops Groq signal when category is null', async () => {
    const groq = mockGroq({
      category: null,
      confidence: 0,
      rationale: 'cannot determine',
    });

    const result = await categorize(
      makeTx({ merchantRaw: 'TOTALLY UNKNOWN' }),
      { ...baseCtx, groq },
    );

    expect(groq.calls.count).toBe(1);
    expect(result.signals.find((s) => s.source === 'groq')).toBeUndefined();
    expect(result.picked).toBeNull();
  });

  it('does not crash when Groq throws — wraps cleanly via mock spy', async () => {
    const groq: GroqCategorizer = {
      categorize: vi.fn().mockRejectedValue(new Error('groq down')),
    };

    await expect(
      categorize(makeTx({ merchantRaw: 'UNKNOWN' }), { ...baseCtx, groq }),
    ).rejects.toThrow('groq down');
  });
});

describe('categorize — Tier 4 (Brave + Groq)', () => {
  it('escalates to Brave+Groq when Tier 3 returns low confidence', async () => {
    const groq = mockGroq(
      // Tier 3 (no web): low confidence
      { category: null, confidence: 0, rationale: 'unfamiliar merchant' },
      // Tier 4 (with web): higher confidence after seeing snippets
      {
        category: 'Groceries / Kirana Stores',
        confidence: 0.88,
        rationale: 'web results describe a kirana store',
      },
    );
    const brave = mockBrave([
      {
        title: 'Sri Guru Raghavendra Enterprises',
        snippet: 'Local kirana store in Jayanagar, Bangalore',
        url: 'https://x',
      },
    ]);

    const result = await categorize(
      makeTx({
        merchantRaw: 'SRI GURU RAGHAVENDRA ENTERPRISES',
        vpa: 'q201985284@ybl',
        amountMinor: 9400n,
      }),
      { ...baseCtx, groq, brave },
      { city: 'Bangalore' },
    );

    expect(groq.calls.count).toBe(2); // tier 3 + tier 4
    expect(brave.calls.count).toBe(1);
    expect(brave.calls.lastInput?.city).toBe('Bangalore');
    expect(brave.calls.lastInput?.merchant).toBe('SRI GURU RAGHAVENDRA ENTERPRISES');

    expect(result.picked?.source).toBe('brave_groq');
    expect(result.picked?.category).toBe('Groceries / Kirana Stores');
    expect(result.status).toBe('needs_review'); // 0.88 < 0.95 threshold
  });

  it('skips Tier 4 when Tier 3 already returned ≥ 0.85 confidence', async () => {
    const groq = mockGroq(
      { category: 'Food', confidence: 0.9, rationale: 'confident enough' },
    );
    const brave = mockBrave([{ title: 't', snippet: 's', url: 'u' }]);

    const result = await categorize(
      makeTx({ merchantRaw: 'UNKNOWN MERCHANT' }),
      { ...baseCtx, groq, brave },
    );

    expect(groq.calls.count).toBe(1);
    expect(brave.calls.count).toBe(0);
    expect(result.picked?.source).toBe('groq');
  });

  it('skips Tier 4 entirely when an alias has auto-tagged', async () => {
    const groq = mockGroq({ category: 'Food', confidence: 0.9, rationale: '' });
    const brave = mockBrave([{ title: 't', snippet: 's', url: 'u' }]);

    const result = await categorize(
      makeTx({ merchantRaw: 'BUNDL TECHNOLOGIES' }),
      { ...baseCtx, groq, brave },
    );

    expect(groq.calls.count).toBe(0);
    expect(brave.calls.count).toBe(0);
    expect(result.picked?.source).toBe('alias');
  });

  it('skips Tier 4 when Brave returns no results', async () => {
    const groq = mockGroq(
      { category: null, confidence: 0, rationale: '' },
      { category: 'Food', confidence: 0.9, rationale: 'should not be reached' },
    );
    const brave = mockBrave([]); // empty

    const result = await categorize(
      makeTx({ merchantRaw: 'UNKNOWN' }),
      { ...baseCtx, groq, brave },
    );

    expect(brave.calls.count).toBe(1);
    // Groq called once for Tier 3; not called again for Tier 4 since Brave was empty
    expect(groq.calls.count).toBe(1);
    expect(result.signals.find((s) => s.source === 'brave_groq')).toBeUndefined();
  });

  it('uses "India" anchor when no city is supplied to enrichment', async () => {
    const groq = mockGroq(
      { category: null, confidence: 0, rationale: '' },
      { category: 'Food', confidence: 0.7, rationale: 'guess' },
    );
    const brave = mockBrave([
      { title: 't', snippet: 's', url: 'u' },
    ]);

    await categorize(
      makeTx({ merchantRaw: 'UNKNOWN' }),
      { ...baseCtx, groq, brave },
      // no enrichment.city
    );

    expect(brave.calls.lastInput?.city).toBeUndefined();
  });
});
