// Budgets — list + upsert. Single-user V1, so no per-user scoping.
//
//   GET  /budgets                 — list all budgets currently set
//   PUT  /budgets/:categoryName   — upsert (creates if absent, updates if exists)
//   DELETE /budgets/:categoryName — remove a budget

import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/client.js';
import { requireApiToken } from '../middleware/auth.js';

const upsertBody = z.object({
  monthly_limit_inr: z.number().positive().max(10_000_000),
  alert_thresholds: z.array(z.number().min(0).max(5)).max(8).optional(),
  enabled: z.boolean().optional(),
});

interface NameParams {
  Params: { categoryName: string };
  Body: unknown;
}

export async function budgetsRoute(app: FastifyInstance): Promise<void> {
  app.get('/', { preHandler: requireApiToken }, async () => {
    const rows = await prisma.budget.findMany({
      include: { category: { select: { name: true } } },
      orderBy: { id: 'asc' },
    });
    return rows.map((r) => ({
      id: r.id,
      category: r.category.name,
      monthly_limit_inr: Number(r.monthlyLimitInr) / 100,
      alert_thresholds: r.alertThresholds.map((t) => Number(t)),
      enabled: r.enabled,
    }));
  });

  app.put<NameParams>(
    '/:categoryName',
    { preHandler: requireApiToken },
    async (req, reply) => {
      const parsed = upsertBody.safeParse(req.body);
      if (!parsed.success) {
        return reply.code(400).send({ error: 'Invalid body', details: parsed.error.format() });
      }

      const decodedName = decodeURIComponent(req.params.categoryName);
      const category = await prisma.category.findUnique({
        where: { name: decodedName },
      });
      if (!category) {
        return reply.code(404).send({ error: `Unknown category: ${decodedName}` });
      }

      // monthly_limit_inr arrives in rupees (e.g. 5000); we store paise.
      const monthlyLimitMinor = BigInt(Math.round(parsed.data.monthly_limit_inr * 100));
      const thresholds = parsed.data.alert_thresholds ?? [0.8, 1.0, 1.1];

      const saved = await prisma.budget.upsert({
        where: { categoryId: category.id },
        update: {
          monthlyLimitInr: monthlyLimitMinor,
          alertThresholds: thresholds,
          enabled: parsed.data.enabled ?? true,
        },
        create: {
          categoryId: category.id,
          monthlyLimitInr: monthlyLimitMinor,
          alertThresholds: thresholds,
          enabled: parsed.data.enabled ?? true,
        },
      });

      return {
        id: saved.id,
        category: decodedName,
        monthly_limit_inr: Number(saved.monthlyLimitInr) / 100,
        alert_thresholds: saved.alertThresholds.map((t) => Number(t)),
        enabled: saved.enabled,
      };
    },
  );

  app.delete<NameParams>(
    '/:categoryName',
    { preHandler: requireApiToken },
    async (req, reply) => {
      const decodedName = decodeURIComponent(req.params.categoryName);
      const category = await prisma.category.findUnique({
        where: { name: decodedName },
      });
      if (!category) {
        return reply.code(404).send({ error: 'Unknown category' });
      }
      await prisma.budget.deleteMany({ where: { categoryId: category.id } });
      return { ok: true };
    },
  );
}
