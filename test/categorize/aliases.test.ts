import { describe, it, expect } from 'vitest';
import {
  stripRoutingPrefix,
  lookupAlias,
  lookupAutopayAlias,
} from '../../src/categorize/aliases.js';
import {
  ROUTING_PREFIXES,
  SEED_ALIASES,
  SEED_AUTOPAY_ALIASES,
} from '../../src/categorize/seed.js';

describe('stripRoutingPrefix', () => {
  it('strips RAZ* prefix', () => {
    expect(stripRoutingPrefix('RAZ*Swiggy', ROUTING_PREFIXES)).toBe('Swiggy');
  });

  it('strips PAYU* prefix', () => {
    expect(stripRoutingPrefix('PAYU*BookMyShow', ROUTING_PREFIXES)).toBe('BookMyShow');
  });

  it('is case-insensitive on the prefix', () => {
    expect(stripRoutingPrefix('raz*Zomato', ROUTING_PREFIXES)).toBe('Zomato');
  });

  it('leaves strings without a prefix unchanged', () => {
    expect(stripRoutingPrefix('BUNDL TECHNOLOGIES', ROUTING_PREFIXES)).toBe('BUNDL TECHNOLOGIES');
  });
});

describe('lookupAlias', () => {
  it('finds BUNDL TECHNOLOGIES → Swiggy → Food (exact match)', () => {
    const hit = lookupAlias('BUNDL TECHNOLOGIES', SEED_ALIASES);
    expect(hit?.canonical).toBe('Swiggy');
    expect(hit?.category).toBe('Food');
  });

  it('finds Swiggy via substring after prefix strip', () => {
    const hit = lookupAlias('Swiggy', SEED_ALIASES);
    expect(hit?.canonical).toBe('Swiggy');
    expect(hit?.category).toBe('Food');
  });

  it('is case-insensitive', () => {
    const hit = lookupAlias('netflix usa', SEED_ALIASES);
    expect(hit?.category).toBe('Subscriptions');
  });

  it('returns null for unknown merchant', () => {
    expect(lookupAlias('SRI GURU RAGHAVENDRA ENTERPRISES', SEED_ALIASES)).toBeNull();
  });
});

describe('lookupAutopayAlias', () => {
  it('matches Railway exactly → Travel', () => {
    const hit = lookupAutopayAlias('Railway', SEED_AUTOPAY_ALIASES);
    expect(hit?.category).toBe('Travel');
  });

  it('matches Claude → Subscriptions', () => {
    const hit = lookupAutopayAlias('Claude', SEED_AUTOPAY_ALIASES);
    expect(hit?.category).toBe('Subscriptions');
  });

  it('returns null for unknown autopay name', () => {
    expect(lookupAutopayAlias('Some Random Bill', SEED_AUTOPAY_ALIASES)).toBeNull();
  });
});
