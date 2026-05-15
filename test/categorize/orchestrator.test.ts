import { describe, it, expect } from 'vitest';
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
import { makeTx, istDate } from '../_helpers/makeTx.js';

const baseCtx: CategorizeContext = {
  aliases: SEED_ALIASES,
  autopayAliases: SEED_AUTOPAY_ALIASES,
  routingPrefixes: ROUTING_PREFIXES,
  rules: [],
};

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
  it('auto-resolves outbound to a personal VPA as P2P', async () => {
    // Updated assertion: VPA-shape confidence was boosted from 0.7 to 0.95
    // so personal-VPA outbound transfers auto-tag without needing user
    // confirmation. UPI credits hit a separate fast-path (handled in the
    // dedicated test below), so we exercise outbound here.
    const result = await categorize(
      makeTx({
        direction: 'out',
        merchantRaw: 'SNEHA R',
        vpa: 's.neha2003rajesh-1@okaxis',
      }),
      baseCtx,
    );
    expect(result.status).toBe('auto_resolved');
    expect(result.picked?.source).toBe('vpa_shape');
    expect(result.picked?.category).toBe('Personal Transfer (Peer-to-Peer)');
    expect(result.picked?.confidence).toBe(0.95);
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

  it('fires the cab rule but VPA-shape wins (auto-tags as P2P)', async () => {
    // Updated for the new VPA-shape confidence (0.95). Both signals
    // still fire — the cab rule emits its 0.6-confidence Travel
    // suggestion, and the VPA shape emits 0.95 P2P. P2P wins on
    // confidence and the row auto-resolves.
    //
    // Trade-off: cab rules can no longer "convert" a P2P-looking
    // transfer into Travel automatically. The user has to re-tag
    // the first ~3 cab rides manually; merchant_patterns learning
    // then auto-tags that driver's VPA as Travel from then on.
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

    expect(result.status).toBe('auto_resolved');
    expect(result.signals.some((s) => s.source === 'user_rule')).toBe(true);
    expect(result.picked?.source).toBe('vpa_shape');
    expect(result.picked?.confidence).toBe(0.95);
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


