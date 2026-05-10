// POST /devices/register — iOS calls this once per launch with its APNs token.
// Idempotent: same token = update lastSeen, new token = insert.

import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/client.js';
import { requireApiToken } from '../middleware/auth.js';

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
}
