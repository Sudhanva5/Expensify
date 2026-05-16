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

const applyPlaceBody = z.object({
  // The Places display name to claim — e.g. "Sri Vishnu Grand Veg".
  // Becomes merchantNormalized on this row AND every same-VPA row.
  placesName: z.string().min(1).max(200),
  category: z.string().min(1).max(120),
  // Optional storefront centroid; we snap location to it so "open in
  // Maps" lands on the actual shop rather than the user's GPS jitter.
  lat: z.number().min(-90).max(90).optional(),
  lng: z.number().min(-180).max(180).optional(),
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
        include: {
          category: { select: { name: true } },
          // Most-recently-arrived receipt for each transaction. Usually
          // one; if Swiggy + delivery-confirmation both attached, the
          // later one wins (it tends to have full details vs. the
          // "order placed" status email).
          receipts: {
            orderBy: { receivedAt: 'desc' },
            take: 1,
          },
        },
      });

      return rows.map((r) => {
        const receipt = r.receipts[0];
        return {
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
          places_suggestions: r.placesSuggestions ?? null,
          receipt: receipt
            ? {
                id: receipt.id,
                gmail_message_id: receipt.gmailMessageId,
                source: receipt.source,
                subject: receipt.subject,
                snippet: receipt.snippet,
                received_at: receipt.receivedAt.toISOString(),
                from_address: receipt.fromAddress,
                amount_inr_minor: receipt.amountInrMinor !== null ? Number(receipt.amountInrMinor) : null,
                order_id: receipt.orderId,
                items: receipt.itemsJson ?? null,
                fees: receipt.feesJson ?? null,
                meta: receipt.metaJson ?? null,
              }
            : null,
        };
      });
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

      // Pattern learning. When the user confirms a category we record it
      // against TWO keys:
      //   1. The VPA (single-hit auto-tag, bulk-updates other rows with
      //      the same VPA — the user's explicit ask "if I tag this, fix
      //      every other row with the same VPA").
      //   2. The merchant's normalized name (3-hit threshold, catches
      //      Surendra Shetty / Veerabharaiah Store with no VPA).
      // Both run best-effort; never blocks the response or throws.
      if (updates.categoryId) {
        try {
          const tx = await prisma.transaction.findUnique({
            where: { id },
            select: { merchantNormalized: true, vpa: true },
          });
          // VPA-pattern first — bulk update fires here.
          if (tx?.vpa) {
            const { recordVpaConfirmation } = await import('../../db/vpaPatterns.js');
            const vpaResult = await recordVpaConfirmation({
              vpa: tx.vpa,
              categoryId: updates.categoryId,
              excludeTransactionId: id,
            });
            req.log.info(
              { vpa: tx.vpa, ...vpaResult },
              '[vpa-pattern] recorded confirmation + bulk-updated rows',
            );
          }
          // Merchant-name pattern (lower priority but still useful for
          // cases where VPA varies but merchant text is stable).
          if (tx?.merchantNormalized) {
            const { recordConfirmation } = await import(
              '../../db/merchantPatterns.js'
            );
            const result = await recordConfirmation({
              merchantNormalized: tx.merchantNormalized,
              categoryId: updates.categoryId,
            });
            req.log.info(
              {
                merchant: tx.merchantNormalized,
                hitCount: result.hitCount,
                autoTagActive: result.autoTagActive,
                categoryChanged: result.categoryChanged,
              },
              '[merchant-pattern] recorded user confirmation',
            );
          }
        } catch (err) {
          req.log.warn({ err }, '[pattern-learning] failed to record confirmation');
        }
      }

      return { ok: true };
    },
  );

  // Claim a Nearby Places suggestion. Sets the storefront name and
  // category on the current row, then bulk-propagates BOTH fields to
  // every other transaction with the same VPA. The bulk update is the
  // "if I claim this VPA belongs to Sri Vishnu Grand Veg, fix all my
  // history" user ask — much stronger than just category propagation.
  app.post<IdParams>(
    '/:id/apply-place',
    { preHandler: requireApiToken },
    async (req, reply) => {
      const { id } = req.params;
      const parsed = applyPlaceBody.safeParse(req.body);
      if (!parsed.success) {
        return reply.code(400).send({ error: 'Invalid body', details: parsed.error.format() });
      }

      const tx = await prisma.transaction.findUnique({
        where: { id },
        select: { id: true, vpa: true, locationLat: true, locationLng: true },
      });
      if (!tx) return reply.code(404).send({ error: 'Transaction not found' });

      const cat = await prisma.category.findUnique({ where: { name: parsed.data.category } });
      if (!cat) return reply.code(400).send({ error: `Unknown category: ${parsed.data.category}` });

      const snapLat = parsed.data.lat ?? null;
      const snapLng = parsed.data.lng ?? null;

      // Update the claimed row first.
      await prisma.transaction.update({
        where: { id },
        data: {
          merchantNormalized: parsed.data.placesName,
          categoryId: cat.id,
          status: 'resolved',
          confidence: 0.99,
          signalSource: 'places',
          ...(snapLat !== null ? { locationLat: snapLat } : {}),
          ...(snapLng !== null ? { locationLng: snapLng } : {}),
          updatedAt: new Date(),
        },
      });

      // Bulk-propagate to every same-VPA row. Skip rows that already
      // match name + category (no-op).
      let bulkUpdated = 0;
      if (tx.vpa) {
        const result = await prisma.transaction.updateMany({
          where: {
            vpa: tx.vpa,
            id: { not: id },
            OR: [
              { merchantNormalized: { not: parsed.data.placesName } },
              { categoryId: { not: cat.id } },
            ],
          },
          data: {
            merchantNormalized: parsed.data.placesName,
            categoryId: cat.id,
            signalSource: 'merchant_pattern',
            confidence: 0.99,
            status: 'resolved',
            updatedAt: new Date(),
          },
        });
        bulkUpdated = result.count;

        // Also record VPA + merchant patterns so future transactions
        // with this VPA auto-tag without needing the Places lookup.
        try {
          const { recordVpaConfirmation } = await import('../../db/vpaPatterns.js');
          await recordVpaConfirmation({
            vpa: tx.vpa,
            categoryId: cat.id,
            excludeTransactionId: id,
          });
        } catch (err) {
          req.log.warn({ err }, '[apply-place] vpa pattern record failed');
        }
      }

      try {
        const { recordConfirmation } = await import('../../db/merchantPatterns.js');
        await recordConfirmation({
          merchantNormalized: parsed.data.placesName,
          categoryId: cat.id,
        });
      } catch (err) {
        req.log.warn({ err }, '[apply-place] merchant pattern record failed');
      }

      req.log.info(
        { txId: id, vpa: tx.vpa, placesName: parsed.data.placesName, bulkUpdated },
        '[apply-place] claimed Places suggestion',
      );
      return { ok: true, bulk_updated: bulkUpdated };
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

      // Fire-and-forget: now that we have lat/lng, run a Places lookup pass
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
