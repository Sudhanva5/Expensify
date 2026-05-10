// iOS-facing endpoints for transactions. V1 endpoints:
//   POST /transactions/:id/location — iOS uploads GPS after a silent push wake-up

import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/client.js';
import { requireApiToken } from '../middleware/auth.js';

const locationBody = z.object({
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  city: z.string().max(120).optional(),
});

interface IdParams {
  Params: { id: string };
  Body: unknown;
}

export async function transactionsRoute(app: FastifyInstance): Promise<void> {
  app.post<IdParams>(
    '/:id/location',
    { preHandler: requireApiToken },
    async (req, reply) => {
      const { id } = req.params;
      const parsed = locationBody.safeParse(req.body);
      if (!parsed.success) {
        return reply.code(400).send({ error: 'Invalid body', details: parsed.error.format() });
      }

      const existing = await prisma.transaction.findUnique({
        where: { id },
        select: { id: true, locationStatus: true },
      });
      if (!existing) {
        return reply.code(404).send({ error: 'Transaction not found' });
      }

      // If we already have a location or this transaction doesn't want one,
      // ignore the upload (idempotent + defensive against late pushes).
      if (
        existing.locationStatus === 'fulfilled' ||
        existing.locationStatus === 'not_applicable'
      ) {
        return { ok: true, ignored: true, reason: existing.locationStatus };
      }

      await prisma.transaction.update({
        where: { id },
        data: {
          locationLat: parsed.data.lat,
          locationLng: parsed.data.lng,
          locationStatus: 'fulfilled',
        },
      });

      return { ok: true };
    },
  );
}
