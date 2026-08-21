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
