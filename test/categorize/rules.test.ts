import { describe, it, expect } from 'vitest';
import { evaluateRule } from '../../src/categorize/rules.js';
import type { UserRule, RuleEvalContext } from '../../src/categorize/types.js';
import { makeTx, istDate } from '../_helpers/makeTx.js';

const baseRule: UserRule = {
  id: 'r1',
  name: 'test rule',
  priority: 100,
  enabled: true,
  conditions: {},
  suggestCategory: 'Travel',
  confidence: 0.6,
};

const noCtx: RuleEvalContext = { aliasMatched: false, vpaShape: 'unknown' };

describe('evaluateRule', () => {
  it('returns false if rule disabled', () => {
    const r = { ...baseRule, enabled: false };
    expect(evaluateRule(r, makeTx(), noCtx)).toBe(false);
  });

  it('matches direction', () => {
    const r = { ...baseRule, conditions: { direction: 'out' as const } };
    expect(evaluateRule(r, makeTx({ direction: 'out' }), noCtx)).toBe(true);
    expect(evaluateRule(r, makeTx({ direction: 'in' }), noCtx)).toBe(false);
  });

  it('matches amountBetween (inclusive)', () => {
    const r = { ...baseRule, conditions: { amountBetween: [200, 350] as [number, number] } };
    expect(evaluateRule(r, makeTx({ amountMinor: 28700n }), noCtx)).toBe(true);
    expect(evaluateRule(r, makeTx({ amountMinor: 20000n }), noCtx)).toBe(true); // boundary
    expect(evaluateRule(r, makeTx({ amountMinor: 35000n }), noCtx)).toBe(true); // boundary
    expect(evaluateRule(r, makeTx({ amountMinor: 19999n }), noCtx)).toBe(false);
    expect(evaluateRule(r, makeTx({ amountMinor: 35001n }), noCtx)).toBe(false);
  });

  it('matches timeOfDayBetween in IST', () => {
    const r = { ...baseRule, conditions: { timeOfDayBetween: ['08:00', '10:30'] as [string, string] } };
    // 2026-05-04 is a Monday
    expect(evaluateRule(r, makeTx({ occurredAt: istDate(2026, 5, 4, 8, 42) }), noCtx)).toBe(true);
    expect(evaluateRule(r, makeTx({ occurredAt: istDate(2026, 5, 4, 7, 59) }), noCtx)).toBe(false);
    expect(evaluateRule(r, makeTx({ occurredAt: istDate(2026, 5, 4, 10, 31) }), noCtx)).toBe(false);
  });

  it('handles timeOfDayBetween that wraps midnight', () => {
    const r = { ...baseRule, conditions: { timeOfDayBetween: ['22:00', '06:00'] as [string, string] } };
    expect(evaluateRule(r, makeTx({ occurredAt: istDate(2026, 5, 4, 23, 30) }), noCtx)).toBe(true);
    expect(evaluateRule(r, makeTx({ occurredAt: istDate(2026, 5, 5, 5, 30) }), noCtx)).toBe(true);
    expect(evaluateRule(r, makeTx({ occurredAt: istDate(2026, 5, 4, 12, 0) }), noCtx)).toBe(false);
  });

  it('matches dayOfWeek (IST)', () => {
    // 2026-05-04 = Monday IST
    const r: UserRule = {
      ...baseRule,
      conditions: { dayOfWeek: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'] },
    };
    expect(evaluateRule(r, makeTx({ occurredAt: istDate(2026, 5, 4, 9, 0) }), noCtx)).toBe(true);
    // 2026-05-09 = Saturday IST
    expect(evaluateRule(r, makeTx({ occurredAt: istDate(2026, 5, 9, 9, 0) }), noCtx)).toBe(false);
  });

  it('matches payeeContains case-insensitively', () => {
    const r = { ...baseRule, conditions: { payeeContains: 'swiggy' } };
    expect(evaluateRule(r, makeTx({ merchantRaw: 'RAZ*Swiggy' }), noCtx)).toBe(true);
    expect(evaluateRule(r, makeTx({ merchantRaw: 'BUNDL TECHNOLOGIES' }), noCtx)).toBe(false);
  });

  it('matches vpaShape via context', () => {
    const r = { ...baseRule, conditions: { vpaShape: 'personal' as const } };
    expect(evaluateRule(r, makeTx(), { aliasMatched: false, vpaShape: 'personal' })).toBe(true);
    expect(evaluateRule(r, makeTx(), { aliasMatched: false, vpaShape: 'merchant' })).toBe(false);
  });

  it('payeeNotInAliasTable=true requires aliasMatched=false', () => {
    const r = { ...baseRule, conditions: { payeeNotInAliasTable: true } };
    expect(evaluateRule(r, makeTx(), { aliasMatched: false, vpaShape: 'unknown' })).toBe(true);
    expect(evaluateRule(r, makeTx(), { aliasMatched: true, vpaShape: 'unknown' })).toBe(false);
  });

  it('all conditions must match (AND)', () => {
    // The Uber-cab pattern: weekday morning, ₹200-350, UPI out, unknown personal
    const uber: UserRule = {
      id: 'uber',
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

    const ctxPersonal: RuleEvalContext = { aliasMatched: false, vpaShape: 'personal' };

    // All match
    expect(
      evaluateRule(
        uber,
        makeTx({
          direction: 'out',
          amountMinor: 28700n,
          occurredAt: istDate(2026, 5, 4, 8, 42),
        }),
        ctxPersonal,
      ),
    ).toBe(true);

    // Wrong day (Sunday 2026-05-10)
    expect(
      evaluateRule(
        uber,
        makeTx({
          direction: 'out',
          amountMinor: 28700n,
          occurredAt: istDate(2026, 5, 10, 8, 42),
        }),
        ctxPersonal,
      ),
    ).toBe(false);

    // Right day but wrong amount
    expect(
      evaluateRule(
        uber,
        makeTx({
          direction: 'out',
          amountMinor: 50000n,
          occurredAt: istDate(2026, 5, 4, 8, 42),
        }),
        ctxPersonal,
      ),
    ).toBe(false);
  });
});
