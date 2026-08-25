// The location-query push is the one wake path that survives Low Power Mode
// and Background App Refresh being off — iOS drops `content-available`
// pushes entirely in that state, but a location push is a *location* wake,
// gated on location authorization instead.
//
// Everything about it is header-shaped, and every header is a chance to get
// it silently wrong: the wrong topic suffix, the wrong push type, or a
// leftover content-available flag all produce a push APNs happily accepts
// and iOS never acts on. That's why this is a pure builder with tests
// rather than fields set inline at the send site.

import { describe, it, expect } from 'vitest';
import type apn from '@parse/node-apn';
import { buildLocationQueryNotification } from '../../src/services/apns.js';

// `headers()` and `compile()` are real methods on node-apn's Notification but
// are absent from its shipped .d.ts. Asserting through this view keeps the
// test honest about the wire bytes without widening the library's types.
interface NotificationWire {
  headers(): Record<string, unknown>;
  compile(): string;
}
const wire = (note: apn.Notification): NotificationWire =>
  note as unknown as NotificationWire;

const BUNDLE = 'NCPUDP.Expensifyy';
const OCCURRED = new Date('2026-08-25T16:14:00.000Z');

describe('buildLocationQueryNotification', () => {
  it('targets the .location-query topic, not the app bundle id', () => {
    const note = buildLocationQueryNotification({
      bundleId: BUNDLE,
      transactionId: 'cmt8v8mb',
      occurredAt: OCCURRED,
    });
    // A location push sent to the plain bundle id is rejected by APNs;
    // the extension listens on this suffix only.
    expect(wire(note).headers()['apns-topic']).toBe('NCPUDP.Expensifyy.location-query');
  });

  it('declares apns-push-type: location', () => {
    const note = buildLocationQueryNotification({
      bundleId: BUNDLE,
      transactionId: 'cmt8v8mb',
      occurredAt: OCCURRED,
    });
    expect(wire(note).headers()['apns-push-type']).toBe('location');
  });

  it('sends at priority 10 — the extension wake is the whole point', () => {
    const note = buildLocationQueryNotification({
      bundleId: BUNDLE,
      transactionId: 'cmt8v8mb',
      occurredAt: OCCURRED,
    });
    // Background pushes must be priority 5; location pushes must not be
    // power-deferred or they land after the user has left the shop.
    expect(wire(note).headers()['apns-priority']).toBe(10);
  });

  it('never sets content-available — that would make it a background push', () => {
    const note = buildLocationQueryNotification({
      bundleId: BUNDLE,
      transactionId: 'cmt8v8mb',
      occurredAt: OCCURRED,
    });
    const compiled = JSON.parse(wire(note).compile()) as {
      aps?: Record<string, unknown>;
    };
    expect(compiled.aps?.['content-available']).toBeUndefined();
  });

  it('carries transactionId and occurredAt so the extension can use the spend-time buffer', () => {
    const note = buildLocationQueryNotification({
      bundleId: BUNDLE,
      transactionId: 'cmt8v8mb',
      occurredAt: OCCURRED,
    });
    const compiled = JSON.parse(wire(note).compile()) as Record<string, unknown>;
    expect(compiled['kind']).toBe('request_location');
    expect(compiled['transactionId']).toBe('cmt8v8mb');
    // Without occurredAt the extension can only report "where the phone is
    // now", which is the bug the buffer exists to prevent.
    expect(compiled['occurredAt']).toBe('2026-08-25T16:14:00.000Z');
  });

  it('stays valid for 30 minutes, unlike the 90s silent push', () => {
    const before = Math.floor(Date.now() / 1000);
    const note = buildLocationQueryNotification({
      bundleId: BUNDLE,
      transactionId: 'cmt8v8mb',
      occurredAt: OCCURRED,
    });
    const expiry = wire(note).headers()['apns-expiration'] as number;
    // A late-delivered location push is still useful: the extension resolves
    // it against the buffer entry nearest occurredAt rather than fetching a
    // fresh fix, so a phone that regains signal 10 minutes later still tags
    // the right place. The silent push can't do that — it needs the app.
    expect(expiry).toBeGreaterThanOrEqual(before + 30 * 60);
    expect(expiry).toBeLessThanOrEqual(before + 30 * 60 + 5);
  });
});
