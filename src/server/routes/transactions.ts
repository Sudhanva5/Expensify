// iOS-facing endpoints for transactions.
//   GET  /transactions                — list recent transactions
//   POST /transactions/:id/location   — iOS uploads GPS after a silent push wake-up

import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/client.js';
import { requireApiToken } from '../middleware/auth.js';
import { recategorizeWithLocation } from '../../pipeline/recategorizeWithLocation.js';

const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 500;

const locationBody = z.object({
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  city: z.string().max(120).optional(),
});

const patchBody = z.object({
  // Category name as a string (e.g. "Food"). Omit to leave unchanged.
  // The endpoint never accepts `null` — clearing a category isn't supported in V1.
  category: z.string().optional(),
  status: z.enum(['pending_review', 'resolved']).optional(),
});

interface IdParams {
  Params: { id: string };
  Body: unknown;
}

export async function transactionsRoute(app: FastifyInstance): Promise<void> {
  // Cheap auth-only check used by the iOS "Test connection" button. Returns
  // 200 if the Bearer token is valid. Doesn't touch any tables.
  app.get(
    '/auth/check',
    { preHandler: requireApiToken },
    async () => ({ ok: true }),
  );

  // IDs of transactions still waiting for a location upload. iOS polls this
  // when it wakes via Significant Location Changes (or when it foregrounds)
  // and backfills each row with the device's current best-known location.
  app.get(
    '/awaiting',
    { preHandler: requireApiToken },
    async () => {
      const rows = await prisma.transaction.findMany({
        where: { locationStatus: 'awaiting' },
        select: { id: true, occurredAt: true },
        orderBy: { occurredAt: 'desc' },
        take: 50,
      });
      return rows.map((r) => ({
        id: r.id,
        occurred_at: r.occurredAt.toISOString(),
      }));
    },
  );

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

  // Update a single transaction. iOS uses this after a swipe-right
  // ("looks ok" → just mark resolved) or after the post-swipe tagging
  // list ("Update Changes" → override category + mark resolved).
  app.patch<IdParams>(
    '/:id',
    { preHandler: requireApiToken },
    async (req, reply) => {
      const { id } = req.params;
      const parsed = patchBody.safeParse(req.body);
      if (!parsed.success) {
        return reply.code(400).send({ error: 'Invalid body', details: parsed.error.format() });
      }

      const updates: { status?: 'pending_review' | 'resolved'; categoryId?: string } = {};

      if (parsed.data.status !== undefined) {
        updates.status = parsed.data.status;
      }

      if (parsed.data.category !== undefined) {
        const cat = await prisma.category.findUnique({
          where: { name: parsed.data.category },
        });
        if (!cat) {
          return reply.code(400).send({ error: `Unknown category: ${parsed.data.category}` });
        }
        updates.categoryId = cat.id;
      }

      if (Object.keys(updates).length === 0) {
        return reply.code(400).send({ error: 'No fields to update' });
      }

      try {
        await prisma.transaction.update({ where: { id }, data: updates });
      } catch {
        return reply.code(404).send({ error: 'Transaction not found' });
      }

      return { ok: true };
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

      // Fire-and-forget: now that we have lat/lng, run a Places + Groq pass
      // to resolve the actual merchant name and category. Logs the outcome
      // but never blocks the iOS upload response.
      void recategorizeWithLocation({
        transactionId: id,
        lat: parsed.data.lat,
        lng: parsed.data.lng,
      })
        .then((outcome) => {
          if (outcome.updated) {
            req.log.info(
              {
                txId: id,
                merchant: outcome.newMerchant,
                category: outcome.newCategory,
                confidence: outcome.confidence,
              },
              'recategorize: updated',
            );
          } else {
            req.log.info({ txId: id, reason: outcome.reason }, 'recategorize: skipped');
          }
        })
        .catch((err) => req.log.error({ err, txId: id }, 'recategorize: failed'));

      return { ok: true };
    },
  );
}
