import { describe, it, expect } from 'vitest';
import {
  AWAITING_GRACE_MS,
  isAwaitingExpired,
} from '../../src/pipeline/locationLifecycle.js';

const HOUR = 60 * 60 * 1000;

describe('isAwaitingExpired', () => {
  const now = new Date('2026-08-20T12:00:00Z');

  it('keeps a spend from minutes ago awaiting — the push may still land', () => {
    const occurredAt = new Date(now.getTime() - 5 * 60 * 1000);
    expect(isAwaitingExpired(occurredAt, now)).toBe(false);
  });

  it('keeps a spend from this morning awaiting — foreground catchup can still ground it from the buffer', () => {
    const occurredAt = new Date(now.getTime() - 6 * HOUR);
    expect(isAwaitingExpired(occurredAt, now)).toBe(false);
  });

  it('expires a spend older than the grace period', () => {
    const occurredAt = new Date(now.getTime() - 25 * HOUR);
    expect(isAwaitingExpired(occurredAt, now)).toBe(true);
  });

  it('treats the grace boundary as not-yet-expired', () => {
    const occurredAt = new Date(now.getTime() - AWAITING_GRACE_MS);
    expect(isAwaitingExpired(occurredAt, now)).toBe(false);
  });

  it('expires the 10-day-old rows that pile up when silent pushes are dropped', () => {
    const occurredAt = new Date(now.getTime() - 10 * 24 * HOUR);
    expect(isAwaitingExpired(occurredAt, now)).toBe(true);
  });

  it('honours a caller-supplied grace period', () => {
    const occurredAt = new Date(now.getTime() - 2 * HOUR);
    expect(isAwaitingExpired(occurredAt, now, 1 * HOUR)).toBe(true);
    expect(isAwaitingExpired(occurredAt, now, 3 * HOUR)).toBe(false);
  });

  it('never expires a future-dated row (clock skew between bank and server)', () => {
    const occurredAt = new Date(now.getTime() + 2 * HOUR);
    expect(isAwaitingExpired(occurredAt, now)).toBe(false);
  });
});
