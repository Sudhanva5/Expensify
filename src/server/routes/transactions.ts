// iOS-facing endpoints for transactions.
//   GET  /transactions                — list recent transactions
//   POST /transactions/:id/location   — iOS uploads GPS after a silent push wake-up

import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/client.js';
import { requireApiToken } from '../middleware/auth.js';

const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 500;

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
  // List recent transactions for the iOS app. Newest first. Includes the
  // resolved category name so the client doesn't have to do a second join.
  app.get(
    '/',
    { preHandler: requireApiToken },
    async (req) => {
      const q = req.query as { limit?: string };
      const limit = Math.min(MAX_LIMIT, Number(q.limit) || DEFAULT_LIMIT);

      const rows = await prisma.transaction.findMany({
        orderBy: { occurredAt: 'desc' },
        take: limit,
        include: { category: { select: { name: true } } },
      });

      return rows.map((r) => ({
        id: r.id,
        amount_inr_minor: r.amountInrMinor !== null ? Number(r.amountInrMinor) : Number(r.amountMinor),
        currency: r.currency,
        merchant_raw: r.merchantRaw,
        merchant_normalized: r.merchantNormalized,
        vpa: r.vpa,
        direction: r.direction,
        instrument: r.instrument,
        occurred_at: r.occurredAt.toISOString(),
        category: r.category?.name ?? null,
        confidence: r.confidence !== null ? Number(r.confidence) : null,
        signal_source: r.signalSource,
        status: r.status,
        location_lat: r.locationLat !== null ? Number(r.locationLat) : null,
        location_lng: r.locationLng !== null ? Number(r.locationLng) : null,
        location_status: r.locationStatus,
      }));
    },
  );

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
