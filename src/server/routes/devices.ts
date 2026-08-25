// POST /devices/register — iOS calls this once per launch with its APNs token.
// POST /devices/test-push — fires a fake visible push to every registered
//                            device. Used by Settings → "Send test notification"
//                            so the user can verify the end-to-end push path
//                            without waiting for an actual budget threshold.

import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/client.js';
import { requireApiToken } from '../middleware/auth.js';
import { sendVisiblePush, sendLocationQueryPush } from '../../services/apns.js';

const registerBody = z.object({
  apns_token: z.string().min(1).max(512),
  // Token from `startMonitoringLocationPushes`, a different credential from
  // apns_token. Optional because it arrives on its own clock and older app
  // builds never send it at all — this endpoint must keep working for them.
  location_push_token: z.string().min(1).max(512).optional(),
});

const testPushBody = z.object({
  // `visible` proves the alert path (budget breaches). `location` proves the
  // location-push extension path, which is the only wake that survives Low
  // Power Mode — and the one you cannot otherwise test without spending
  // real money and waiting for HDFC.
  kind: z.enum(['visible', 'location']).default('visible'),
  // Which row the location push should ask about. Defaults to the most
  // recent row still awaiting a location, so the test does real work.
  transactionId: z.string().min(1).max(64).optional(),
});

export async function devicesRoute(app: FastifyInstance): Promise<void> {
  app.post('/register', { preHandler: requireApiToken }, async (req, reply) => {
    const parsed = registerBody.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'Invalid body', details: parsed.error.format() });
    }

    const { apns_token, location_push_token } = parsed.data;

    // A location-push token belongs to exactly one device. If it was
    // previously seen against a different APNs token (app reinstalled, so
    // iOS minted a fresh APNs token but kept the location one), clear the
    // stale holder first — the column is unique and would otherwise reject
    // this upsert.
    if (location_push_token) {
      await prisma.deviceToken.updateMany({
        where: {
          locationPushToken: location_push_token,
          apnsToken: { not: apns_token },
        },
        data: { locationPushToken: null },
      });
    }

    const row = await prisma.deviceToken.upsert({
      where: { apnsToken: apns_token },
      update: {
        lastSeen: new Date(),
        // Only write when the client sent one. An older build that omits the
        // field must not wipe a good token off the row.
        ...(location_push_token ? { locationPushToken: location_push_token } : {}),
      },
      create: {
        apnsToken: apns_token,
        locationPushToken: location_push_token ?? null,
      },
    });

    return {
      ok: true,
      deviceId: row.id,
      locationPushRegistered: row.locationPushToken !== null,
    };
  });

  // Test push. Sends a synthetic budget alert to every registered device
  // so the user can prove that the APNs path is healthy without crossing
  // a real budget threshold. Returns per-device delivery status so the
  // iOS Settings UI can show which (if any) tokens succeeded.
  app.post('/test-push', { preHandler: requireApiToken }, async (req) => {
    const parsedBody = testPushBody.safeParse(req.body ?? {});
    const kind = parsedBody.success ? parsedBody.data.kind : 'visible';
    const requestedTxId = parsedBody.success ? parsedBody.data.transactionId : undefined;

    const devices = await prisma.deviceToken.findMany();
    if (devices.length === 0) {
      return { ok: false, reason: 'no_registered_devices', devices: [] };
    }

    if (kind === 'location') {
      // Pick a real row so the push does real work: the newest one still
      // awaiting a location, falling back to the newest outflow. Without a
      // transaction id the extension has nothing to report against.
      const target = requestedTxId
        ? await prisma.transaction.findUnique({
            where: { id: requestedTxId },
            select: { id: true, occurredAt: true },
          })
        : ((await prisma.transaction.findFirst({
            where: { locationStatus: 'awaiting' },
            select: { id: true, occurredAt: true },
            orderBy: { occurredAt: 'desc' },
          })) ??
          (await prisma.transaction.findFirst({
            where: { direction: 'out' },
            select: { id: true, occurredAt: true },
            orderBy: { occurredAt: 'desc' },
          })));

      if (!target) {
        return { ok: false, reason: 'no_transaction_to_test_against', devices: [] };
      }

      const locationResults = await Promise.all(
        devices.map(async (d) => {
          if (!d.locationPushToken) {
            return {
              tokenPrefix: d.apnsToken.slice(0, 12),
              lastSeen: d.lastSeen.toISOString(),
              delivered: false,
              reason: 'no_location_push_token',
            };
          }
          const ok = await sendLocationQueryPush({
            locationPushToken: d.locationPushToken,
            transactionId: target.id,
            occurredAt: target.occurredAt,
          });
          return {
            tokenPrefix: d.locationPushToken.slice(0, 12),
            lastSeen: d.lastSeen.toISOString(),
            delivered: ok,
          };
        }),
      );

      req.log.info(
        { results: locationResults, transactionId: target.id },
        '[test-push] location-query fan-out complete',
      );
      return {
        ok: locationResults.some((r) => r.delivered),
        kind: 'location',
        transactionId: target.id,
        devices: locationResults,
      };
    }

    const results = await Promise.all(
      devices.map(async (d) => {
        // Title/body MUST stay in sync with the literals shown in
        // DiagnosticsView.notificationsSection — the iOS preview is
        // promising the user exactly this banner.
        const ok = await sendVisiblePush({
          apnsToken: d.apnsToken,
          title: 'Test from Expensify',
          body: 'Your budget alert pipeline is wired up correctly. Real alerts will land here.',
          payload: { kind: 'test_push', sentAt: new Date().toISOString() },
        });
        return {
          tokenPrefix: d.apnsToken.slice(0, 12),
          lastSeen: d.lastSeen.toISOString(),
          delivered: ok,
        };
      }),
    );

    const anyOk = results.some((r) => r.delivered);
    req.log.info({ results }, '[test-push] fan-out complete');
    return { ok: anyOk, devices: results };
  });
}
