// User rules — list / create / update / delete. Drives the contextual
// auto-tagging that goes beyond merchant identity (e.g., "200-400 ₹ near
// my office between 8-10am on weekdays → Travel").
//
//   GET    /rules         — list all rules (enabled + disabled)
//   POST   /rules         — create a rule
//   PATCH  /rules/:id     — update (rename, toggle enabled, change conditions)
//   DELETE /rules/:id     — remove a rule
//
// The iOS "Create rule from this transaction" wizard hits POST with a
// payload pre-filled from a tx (amount ±20%, time ±1hr, location-within-
// radius, same instrument). Conditions are stored as opaque JSONB —
// validation here is structural only, the evaluator handles semantics.

import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { Prisma } from '@prisma/client';
import { prisma } from '../../db/client.js';
import { requireApiToken } from '../middleware/auth.js';
import { CATEGORIES, DAYS_OF_WEEK } from '../../categorize/types.js';

const conditionsSchema = z
  .object({
    direction: z.enum(['in', 'out']).optional(),
    instrument: z.union([z.string(), z.array(z.string())]).optional(),
    amountBetween: z.tuple([z.number(), z.number()]).optional(),
    timeOfDayBetween: z.tuple([z.string(), z.string()]).optional(),
    dayOfWeek: z.array(z.enum(DAYS_OF_WEEK)).optional(),
    payeeContains: z.string().optional(),
    payeeRegex: z.string().optional(),
    payeeNotInAliasTable: z.boolean().optional(),
    vpaShape: z.enum(['personal', 'merchant', 'unknown']).optional(),
    locationWithinRadius: z
      .object({
        lat: z.number().min(-90).max(90),
        lng: z.number().min(-180).max(180),
        meters: z.number().positive().max(50_000),
      })
      .optional(),
  })
  .strict();

const createBody = z.object({
  name: z.string().min(1).max(120),
  priority: z.number().int().min(0).max(10_000).optional(),
  enabled: z.boolean().optional(),
  conditions: conditionsSchema,
  category: z.enum(CATEGORIES),
  confidence: z.number().min(0).max(1).optional(),
});

const patchBody = z.object({
  name: z.string().min(1).max(120).optional(),
  priority: z.number().int().min(0).max(10_000).optional(),
  enabled: z.boolean().optional(),
  conditions: conditionsSchema.optional(),
  category: z.enum(CATEGORIES).optional(),
  confidence: z.number().min(0).max(1).optional(),
});

interface IdParams {
  Params: { id: string };
  Body: unknown;
}

export async function rulesRoute(app: FastifyInstance): Promise<void> {
  app.get('/', { preHandler: requireApiToken }, async () => {
    const rows = await prisma.userRule.findMany({
      include: { category: { select: { name: true } } },
      orderBy: [{ priority: 'desc' }, { createdAt: 'asc' }],
    });
    return rows.map((r) => ({
      id: r.id,
      name: r.name,
      priority: r.priority,
      enabled: r.enabled,
      conditions: r.conditions,
      category: r.category.name,
      confidence: Number(r.defaultConfidence),
      hit_count: r.hitCount,
      created_at: r.createdAt.toISOString(),
      updated_at: r.updatedAt.toISOString(),
    }));
  });

  app.post('/', { preHandler: requireApiToken }, async (req, reply) => {
    const parsed = createBody.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'Invalid body', details: parsed.error.format() });
    }
    const cat = await prisma.category.findUnique({ where: { name: parsed.data.category } });
    if (!cat) return reply.code(400).send({ error: `Unknown category: ${parsed.data.category}` });

    const saved = await prisma.userRule.create({
      data: {
        name: parsed.data.name,
        priority: parsed.data.priority ?? 100,
        enabled: parsed.data.enabled ?? true,
        conditions: parsed.data.conditions as unknown as Prisma.InputJsonValue,
        categoryId: cat.id,
        defaultConfidence: new Prisma.Decimal(parsed.data.confidence ?? 0.95),
      },
      include: { category: { select: { name: true } } },
    });

    return reply.code(201).send({
      id: saved.id,
      name: saved.name,
      priority: saved.priority,
      enabled: saved.enabled,
      conditions: saved.conditions,
      category: saved.category.name,
      confidence: Number(saved.defaultConfidence),
      hit_count: saved.hitCount,
      created_at: saved.createdAt.toISOString(),
      updated_at: saved.updatedAt.toISOString(),
    });
  });

  app.patch<IdParams>('/:id', { preHandler: requireApiToken }, async (req, reply) => {
    const parsed = patchBody.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'Invalid body', details: parsed.error.format() });
    }
    const data: Prisma.UserRuleUpdateInput = {};
    if (parsed.data.name !== undefined) data.name = parsed.data.name;
    if (parsed.data.priority !== undefined) data.priority = parsed.data.priority;
    if (parsed.data.enabled !== undefined) data.enabled = parsed.data.enabled;
    if (parsed.data.conditions !== undefined) {
      data.conditions = parsed.data.conditions as unknown as Prisma.InputJsonValue;
    }
    if (parsed.data.confidence !== undefined) {
      data.defaultConfidence = new Prisma.Decimal(parsed.data.confidence);
    }
    if (parsed.data.category !== undefined) {
      const cat = await prisma.category.findUnique({ where: { name: parsed.data.category } });
      if (!cat) return reply.code(400).send({ error: `Unknown category: ${parsed.data.category}` });
      data.category = { connect: { id: cat.id } };
    }
    if (Object.keys(data).length === 0) {
      return reply.code(400).send({ error: 'No fields to update' });
    }
    try {
      await prisma.userRule.update({ where: { id: req.params.id }, data });
    } catch {
      return reply.code(404).send({ error: 'Rule not found' });
    }
    return { ok: true };
  });

  app.delete<IdParams>('/:id', { preHandler: requireApiToken }, async (req, reply) => {
    try {
      await prisma.userRule.delete({ where: { id: req.params.id } });
    } catch {
      return reply.code(404).send({ error: 'Rule not found' });
    }
    return { ok: true };
  });
}
