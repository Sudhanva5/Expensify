// Lifecycle policy for `locationStatus = 'awaiting'` rows.
//
// Why this exists: a row is born `awaiting` and only ever leaves that state
// when iOS successfully uploads a GPS fix. Nothing ever gave up. Every
// silent push that iOS dropped (app force-quit, Low Power Mode, APNs
// throttling, the 90s expiry firing) left a row stuck `awaiting` forever —
// the iOS chip renders "locating…" in perpetuity, and because
// GET /transactions/awaiting is `take: 50` ordered by occurredAt desc, a
// large enough backlog pushes still-recoverable rows off the end of the
// list so the foreground backfill can never even see them.
//
// The grace period is deliberately generous. It is NOT "how long until the
// push gives up" (that's 90s of APNs expiry) — it's "how long the foreground
// catchup still has a realistic shot at grounding this row from the
// on-device spend-time buffer". The buffer keeps 14 days of history, but in
// practice the user opens the app at least daily, so a row that survived a
// full day of foregrounding is never going to resolve itself.

/// How long a row may sit `awaiting` before we admit we missed it.
export const AWAITING_GRACE_MS = 24 * 60 * 60 * 1000;

/**
 * Does a freshly-parsed transaction want a GPS round-trip?
 *
 * Every outflow does. This used to consult `detectOnlineMerchant` on the
 * bank's payee text and skip the round-trip when it looked like a website,
 * and that classifier was wrong in both directions on real data:
 *
 *   • "paytm-57338997" — a petrol pump in Electronic City, reached through
 *     a Paytm terminal — matched the PAYTM rail prefix and was suppressed.
 *     No GPS, no Places suggestions, merchant name typed in by hand.
 *   • "PHP*REDBUS" — a bus booked from the sofa — did NOT match, because
 *     the pattern was anchored at `^` and the acquirer prefix came first.
 *     Silent push fired for a spend with no storefront.
 *
 * A payment rail carries in-person QR terminals and web checkouts alike,
 * so its prefix cannot answer this question. Asking every time is both
 * simpler and more accurate: the cost of a needless GPS ping is one silent
 * push the sweep later retires as `missed`, while the cost of a wrongly
 * skipped one is a permanently context-free transaction.
 *
 * The two exclusions that remain are structural rather than statistical —
 * they hold no matter what the payee text says:
 *   • inflow — somebody paid you; you weren't necessarily anywhere.
 *   • autopay — an e-mandate bill is charged in the cloud on the bank's
 *     schedule, quite possibly while you're asleep.
 *
 * `detectOnlineMerchant` still runs later, inside recategorizeWithLocation,
 * to decide the narrower question of whether Places may auto-RENAME a row.
 */
export function initialLocationStatus(tx: {
  direction: 'in' | 'out';
  isAutopay: boolean;
}): 'awaiting' | 'not_applicable' {
  if (tx.direction === 'in') return 'not_applicable';
  if (tx.isAutopay) return 'not_applicable';
  return 'awaiting';
}

/**
 * Should this awaiting row be transitioned to `missed`?
 *
 * Future-dated rows are never expired: HDFC timestamps come from the bank's
 * clock and occasionally land slightly ahead of ours, and expiring a row we
 * haven't even reached yet would be strictly wrong.
 */
export function isAwaitingExpired(
  occurredAt: Date,
  now: Date,
  graceMs: number = AWAITING_GRACE_MS,
): boolean {
  const age = now.getTime() - occurredAt.getTime();
  if (age < 0) return false;
  return age > graceMs;
}

/// Cutoff timestamp for a bulk `occurredAt < cutoff` sweep — the query-shaped
/// counterpart to `isAwaitingExpired`, so both paths share one definition of
/// "too old".
export function awaitingExpiryCutoff(
  now: Date,
  graceMs: number = AWAITING_GRACE_MS,
): Date {
  return new Date(now.getTime() - graceMs);
}
