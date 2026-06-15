// Spend-query tools — the "where did my money go" surface. All read-only.

import { z } from 'zod';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { Prisma } from '@prisma/client';
import { prisma } from '../../db/client.js';
import { CATEGORIES } from '../../categorize/types.js';
import {
  asJsonText,
  minorToInr,
  inrToMinor,
  startOfIstDay,
  endOfIstDay,
  monthBounds,
} from '../formatters.js';
import {
  INCLUDE_VALUES,
  expandTransaction,
  prismaIncludeFor,
  type Include,
} from '../expand.js';

const IncludeArg = z
  .array(z.enum(INCLUDE_VALUES))
  .optional()
  .describe(
    'Optional richer fields to embed on each transaction. Choose any subset of "receipt" (Swiggy/MMT/etc. line items), "places" (nearby-Places suggestions JSON), "location" (lat/lng/status), "fx" (source currency + bank rate + markup), "email" (raw HDFC subject + snippet). Omit for the lightweight shape.',
  );

export function registerSpendTools(server: McpServer): void {
  server.registerTool(
    'list_transactions',
    {
      title: 'List transactions',
      description:
        'List transactions with optional filters. Sorted by occurredAt DESC. Use this for any question like "show me X" or "what did I spend at Y last week". Default limit 25, max 100. Amounts are in INR (rupees).',
      inputSchema: {
        category: z
          .enum(CATEGORIES)
          .optional()
          .describe('One of the 7 V1 categories. Omit for all categories.'),
        direction: z.enum(['in', 'out']).optional(),
        merchantContains: z
          .string()
          .optional()
          .describe(
            'Case-insensitive substring match on merchantNormalized OR merchantRaw OR vpa.',
          ),
        minAmountInr: z.number().nonnegative().optional(),
        maxAmountInr: z.number().nonnegative().optional(),
        startDate: z
          .string()
          .regex(/^\d{4}-\d{2}-\d{2}$/)
          .optional()
          .describe('IST inclusive lower bound, YYYY-MM-DD.'),
        endDate: z
          .string()
          .regex(/^\d{4}-\d{2}-\d{2}$/)
          .optional()
          .describe('IST inclusive upper bound, YYYY-MM-DD.'),
        instrument: z
          .string()
          .optional()
          .describe('e.g. "account_5264", "card_3328", "card_3803".'),
        status: z
          .enum(['awaiting_location', 'pending_review', 'resolved'])
          .optional(),
        limit: z.number().int().min(1).max(100).default(25),
        include: IncludeArg,
      },
    },
    async (args) => {
      const where: Prisma.TransactionWhereInput = {};
      if (args.direction) where.direction = args.direction;
      if (args.instrument) where.instrument = args.instrument;
      if (args.status) where.status = args.status;
      if (args.category) where.category = { name: args.category };
      if (args.merchantContains) {
        const q = args.merchantContains;
        where.OR = [
          { merchantNormalized: { contains: q, mode: 'insensitive' } },
          { merchantRaw: { contains: q, mode: 'insensitive' } },
          { vpa: { contains: q, mode: 'insensitive' } },
        ];
      }
      if (
        args.minAmountInr !== undefined ||
        args.maxAmountInr !== undefined
      ) {
        const amount: Prisma.BigIntFilter = {};
        if (args.minAmountInr !== undefined) amount.gte = inrToMinor(args.minAmountInr);
        if (args.maxAmountInr !== undefined) amount.lte = inrToMinor(args.maxAmountInr);
        where.amountInrMinor = amount;
      }
      if (args.startDate || args.endDate) {
        const occurred: Prisma.DateTimeFilter = {};
        if (args.startDate) occurred.gte = startOfIstDay(args.startDate);
        if (args.endDate) occurred.lt = endOfIstDay(args.endDate);
        where.occurredAt = occurred;
      }

      const includes = new Set<Include>(args.include ?? []);
      const rows = await prisma.transaction.findMany({
        where,
        orderBy: { occurredAt: 'desc' },
        take: args.limit,
        include: prismaIncludeFor(includes),
      });

      return {
        content: [
          asJsonText({
            count: rows.length,
            transactions: rows.map((r) => expandTransaction(r, includes)),
          }),
        ],
      };
    },
  );

  server.registerTool(
    'monthly_summary',
    {
      title: 'Monthly category summary',
      description:
        'Spend breakdown by category for one calendar month (IST). Returns outflow per category sorted high → low, total outflow, total inflow, and net. Use for "how did June look?" or "what was my food bill last month?"',
      inputSchema: {
        yearMonth: z
          .string()
          .regex(/^\d{4}-\d{2}$/)
          .describe('YYYY-MM in IST, e.g. "2026-06".'),
      },
    },
    async (args) => {
      const { start, end } = monthBounds(args.yearMonth);

      const grouped = await prisma.transaction.groupBy({
        by: ['categoryId', 'direction'],
        where: { occurredAt: { gte: start, lt: end } },
        _sum: { amountInrMinor: true },
        _count: { _all: true },
      });

      const categories = await prisma.category.findMany({
        select: { id: true, name: true },
      });
      const nameOf = (id: string | null): string =>
        (id && categories.find((c) => c.id === id)?.name) || 'Uncategorized';

      const outflow = grouped
        .filter((g) => g.direction === 'out')
        .map((g) => ({
          category: nameOf(g.categoryId),
          totalInr: minorToInr(g._sum.amountInrMinor) ?? 0,
          count: g._count._all,
        }))
        .sort((a, b) => b.totalInr - a.totalInr);

      const totalOutflowInr = outflow.reduce((s, x) => s + x.totalInr, 0);
      const totalInflowInr = grouped
        .filter((g) => g.direction === 'in')
        .reduce((s, g) => s + (minorToInr(g._sum.amountInrMinor) ?? 0), 0);

      return {
        content: [
          asJsonText({
            month: args.yearMonth,
            timezone: 'Asia/Kolkata',
            outflowByCategory: outflow,
            totalOutflowInr,
            totalInflowInr,
            netInr: totalInflowInr - totalOutflowInr,
          }),
        ],
      };
    },
  );

  server.registerTool(
    'top_merchants',
    {
      title: 'Top merchants by spend',
      description:
        'Top N merchants by total outflow over an arbitrary date range. Defaults to the last 30 days. Groups on merchantNormalized so "RAJESH KUMAR" rows stay distinct from "BUNDL TECHNOLOGIES → Swiggy" rows post-normalization.',
      inputSchema: {
        startDate: z
          .string()
          .regex(/^\d{4}-\d{2}-\d{2}$/)
          .optional()
          .describe('IST inclusive lower bound. Defaults to 30 days ago.'),
        endDate: z
          .string()
          .regex(/^\d{4}-\d{2}-\d{2}$/)
          .optional()
          .describe('IST inclusive upper bound. Defaults to today.'),
        limit: z.number().int().min(1).max(50).default(10),
      },
    },
    async (args) => {
      const end = args.endDate
        ? endOfIstDay(args.endDate)
        : new Date();
      const start = args.startDate
        ? startOfIstDay(args.startDate)
        : new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);

      const grouped = await prisma.transaction.groupBy({
        by: ['merchantNormalized'],
        where: {
          occurredAt: { gte: start, lt: end },
          direction: 'out',
        },
        _sum: { amountInrMinor: true },
        _count: { _all: true },
        orderBy: { _sum: { amountInrMinor: 'desc' } },
        take: args.limit,
      });

      return {
        content: [
          asJsonText({
            start: start.toISOString(),
            end: end.toISOString(),
            merchants: grouped.map((g) => ({
              merchant: g.merchantNormalized,
              totalInr: minorToInr(g._sum.amountInrMinor) ?? 0,
              count: g._count._all,
            })),
          }),
        ],
      };
    },
  );

  server.registerTool(
    'total_by_category',
    {
      title: 'Spend per category over a range',
      description:
        'Total outflow per category across an arbitrary date range. Useful for "how much did I spend on Food this quarter?" or "compare Travel vs Subscriptions YTD".',
      inputSchema: {
        startDate: z
          .string()
          .regex(/^\d{4}-\d{2}-\d{2}$/)
          .describe('IST inclusive lower bound, YYYY-MM-DD.'),
        endDate: z
          .string()
          .regex(/^\d{4}-\d{2}-\d{2}$/)
          .describe('IST inclusive upper bound, YYYY-MM-DD.'),
      },
    },
    async (args) => {
      const start = startOfIstDay(args.startDate);
      const end = endOfIstDay(args.endDate);

      const grouped = await prisma.transaction.groupBy({
        by: ['categoryId'],
        where: {
          occurredAt: { gte: start, lt: end },
          direction: 'out',
        },
        _sum: { amountInrMinor: true },
        _count: { _all: true },
      });
      const categories = await prisma.category.findMany({
        select: { id: true, name: true },
      });
      const result = grouped
        .map((g) => ({
          category:
            categories.find((c) => c.id === g.categoryId)?.name ??
            'Uncategorized',
          totalInr: minorToInr(g._sum.amountInrMinor) ?? 0,
          count: g._count._all,
        }))
        .sort((a, b) => b.totalInr - a.totalInr);

      return {
        content: [
          asJsonText({
            start: start.toISOString(),
            end: end.toISOString(),
            totalOutflowInr: result.reduce((s, x) => s + x.totalInr, 0),
            categories: result,
          }),
        ],
      };
    },
  );

  server.registerTool(
    'search_merchant',
    {
      title: 'Find transactions by merchant text',
      description:
        'Fuzzy search across merchantNormalized + merchantRaw + vpa. Returns matching transactions, newest first. Prefer this when the user names a merchant ("did I pay redBus this month?", "all my Swiggy orders") — it captures variant spellings the bank produces.',
      inputSchema: {
        query: z.string().min(1).describe('Substring to look for.'),
        limit: z.number().int().min(1).max(50).default(20),
        include: IncludeArg,
      },
    },
    async (args) => {
      const q = args.query;
      const includes = new Set<Include>(args.include ?? []);
      const rows = await prisma.transaction.findMany({
        where: {
          OR: [
            { merchantNormalized: { contains: q, mode: 'insensitive' } },
            { merchantRaw: { contains: q, mode: 'insensitive' } },
            { vpa: { contains: q, mode: 'insensitive' } },
          ],
        },
        orderBy: { occurredAt: 'desc' },
        take: args.limit,
        include: prismaIncludeFor(includes),
      });
      return {
        content: [
          asJsonText({
            query: q,
            count: rows.length,
            transactions: rows.map((r) => expandTransaction(r, includes)),
          }),
        ],
      };
    },
  );
}
