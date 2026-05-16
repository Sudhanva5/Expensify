// POST /devices/register — iOS calls this once per launch with its APNs token.
// POST /devices/test-push — fires a fake visible push to every registered
//                            device. Used by Settings → "Send test notification"
//                            so the user can verify the end-to-end push path
//                            without waiting for an actual budget threshold.

import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/client.js';
import { requireApiToken } from '../middleware/auth.js';
import { sendVisiblePush } from '../../services/apns.js';

const registerBody = z.object({
  apns_token: z.string().min(1).max(512),
});

export async function devicesRoute(app: FastifyInstance): Promise<void> {
  app.post('/register', { preHandler: requireApiToken }, async (req, reply) => {
    const parsed = registerBody.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'Invalid body', details: parsed.error.format() });
    }

    const { apns_token } = parsed.data;
    const row = await prisma.deviceToken.upsert({
      where: { apnsToken: apns_token },
      update: { lastSeen: new Date() },
      create: { apnsToken: apns_token },
    });

    return { ok: true, deviceId: row.id };
  });

  // Test push. Sends a synthetic budget alert to every registered device
  // so the user can prove that the APNs path is healthy without crossing
  // a real budget threshold. Returns per-device delivery status so the
  // iOS Settings UI can show which (if any) tokens succeeded.
  app.post('/test-push', { preHandler: requireApiToken }, async (req) => {
    const devices = await prisma.deviceToken.findMany();
    if (devices.length === 0) {
      return { ok: false, reason: 'no_registered_devices', devices: [] };
    }

    const results = await Promise.all(
      devices.map(async (d) => {
        const ok = await sendVisiblePush({
          apnsToken: d.apnsToken,
          title: 'Test notification',
          body: 'If you see this, push delivery is working end-to-end.',
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
