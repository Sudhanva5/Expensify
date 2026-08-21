// In-process scheduler for periodic maintenance jobs. Lives inside the API
// service so we don't need a separate Railway Cron service for V1.
//
// Currently registers:
//   - Gmail watch refresh: re-registers the watch with Pub/Sub before it
//     expires (Gmail caps watch at 7 days). Runs 30s after boot, then every
//     24 hours, but only actually re-registers if the current watch is within
//     24 hours of expiry (or has no expiry recorded).
//   - Location sweep: retires `awaiting` rows that iOS never grounded, so
//     they stop rendering "locating…" forever and stop crowding the
//     awaiting list. Hourly.

import type { FastifyInstance } from 'fastify';
import { authorizedClient } from '../gmail/oauth.js';
import { registerWatch } from '../gmail/watch.js';
import { prisma } from '../db/client.js';
import { expireStaleAwaitingLocations } from '../db/transactions.js';
import {
  AWAITING_GRACE_MS,
  awaitingExpiryCutoff,
} from '../pipeline/locationLifecycle.js';

const ONE_DAY_MS = 24 * 60 * 60 * 1000;
const ONE_HOUR_MS = 60 * 60 * 1000;
const REFRESH_BUFFER_MS = ONE_DAY_MS; // refresh if expires within 24h
const CHECK_INTERVAL_MS = ONE_DAY_MS;
const STARTUP_DELAY_MS = 30 * 1000;
const LOCATION_SWEEP_INTERVAL_MS = ONE_HOUR_MS;
// Offset from the watch-refresh tick so the two jobs don't contend for the
// same Postgres connection on a cold boot.
const LOCATION_SWEEP_STARTUP_DELAY_MS = 60 * 1000;

export function scheduleWatchRefresh(app: FastifyInstance): void {
  const tick = () => {
    void maybeRefreshWatch(app).catch((err) =>
      app.log.error({ err }, 'watch refresh tick failed'),
    );
  };

  setTimeout(tick, STARTUP_DELAY_MS);
  setInterval(tick, CHECK_INTERVAL_MS);

  app.log.info(
    `Gmail watch refresh scheduled (first check in ${STARTUP_DELAY_MS / 1000}s, then every ${CHECK_INTERVAL_MS / ONE_DAY_MS}d)`,
  );
}

/**
 * Retire awaiting rows the phone was never able to ground.
 *
 * Deliberately does NOT try to guess a location for them — a row we can't
 * place honestly reads better as "no location" than as wherever the user
 * happened to be when the app next opened. Marking them `missed` is the
 * whole point: it's the only exit from `awaiting` other than a real fix.
 */
export function scheduleLocationSweep(app: FastifyInstance): void {
  const tick = () => {
    void sweepStaleAwaitingLocations(app).catch((err) =>
      app.log.error({ err }, 'location sweep tick failed'),
    );
  };

  setTimeout(tick, LOCATION_SWEEP_STARTUP_DELAY_MS);
  setInterval(tick, LOCATION_SWEEP_INTERVAL_MS);

  app.log.info(
    `Location sweep scheduled (grace ${AWAITING_GRACE_MS / ONE_HOUR_MS}h, every ${LOCATION_SWEEP_INTERVAL_MS / ONE_HOUR_MS}h)`,
  );
}

async function sweepStaleAwaitingLocations(app: FastifyInstance): Promise<void> {
  const cutoff = awaitingExpiryCutoff(new Date());
  const count = await expireStaleAwaitingLocations(cutoff);
  if (count > 0) {
    app.log.info(
      { count, cutoff: cutoff.toISOString() },
      'location sweep: retired stale awaiting rows to missed',
    );
  }
}

async function maybeRefreshWatch(app: FastifyInstance): Promise<void> {
  const oauth = await prisma.gmailOauth.findFirst();
  if (!oauth?.refreshToken) {
    app.log.warn(
      'Gmail watch refresh skipped: no refresh token in DB. Run scripts/gmail-auth.ts.',
    );
    return;
  }

  const expiresAt = oauth.watchExpiresAt;
  const now = Date.now();
  const msUntilExpiry = expiresAt ? expiresAt.getTime() - now : -1;

  if (expiresAt && msUntilExpiry > REFRESH_BUFFER_MS) {
    app.log.info(
      { expiresAt: expiresAt.toISOString(), daysLeft: (msUntilExpiry / ONE_DAY_MS).toFixed(2) },
      'Gmail watch still valid; skipping refresh',
    );
    return;
  }

  const topicName = process.env['GOOGLE_PUBSUB_TOPIC'];
  if (!topicName) {
    app.log.error('GOOGLE_PUBSUB_TOPIC not set; cannot refresh Gmail watch');
    return;
  }

  app.log.info(
    expiresAt
      ? { expiresAt: expiresAt.toISOString() }
      : { reason: 'no expiry recorded' },
    'Refreshing Gmail watch',
  );

  try {
    const auth = await authorizedClient();
    const result = await registerWatch(auth, { topicName });
    app.log.info(
      {
        historyId: result.historyId,
        expiresAt: new Date(result.expirationMs).toISOString(),
      },
      'Gmail watch refreshed',
    );
  } catch (err) {
    app.log.error({ err }, 'Gmail watch refresh FAILED — emails will stop arriving when current watch expires');
  }
}
