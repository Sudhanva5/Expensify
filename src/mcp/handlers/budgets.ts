// Budget + alert inspection tools.

import { z } from 'zod';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { prisma } from '../../db/client.js';
import {
  asJsonText,
  minorToInr,
  monthBounds,
  currentMonthIst,
} from '../formatters.js';

export function registerBudgetTools(server: McpServer): void {
  server.registerTool(
    'current_budget_status',
    {
      title: 'Budget status for this month',
      description:
        'Returns MTD spend vs monthly limit for every configured budget. Computes percent consumed, remaining INR, and which alert thresholds have already fired this month. Sorted by % consumed descending (the categories you should worry about first).',
      inputSchema: {
        yearMonth: z
          .string()
          .regex(/^\d{4}-\d{2}$/)
          .optional()
          .describe(
            'YYYY-MM in IST. Defaults to the current IST month — use this default unless the user asks about a specific past month.',
          ),
      },
    },
    async (args) => {
      const yearMonth = args.yearMonth ?? currentMonthIst();
      const { start, end } = monthBounds(yearMonth);

      const budgets = await prisma.budget.findMany({
        include: {
          category: { select: { name: true } },
          alerts: { where: { yearMonth }, orderBy: { firedAt: 'asc' } },
        },
      });

      const rows = await Promise.all(
        budgets.map(async (b) => {
          const agg = await prisma.transaction.aggregate({
            where: {
              categoryId: b.categoryId,
              direction: 'out',
              occurredAt: { gte: start, lt: end },
            },
            _sum: { amountInrMinor: true },
            _count: { _all: true },
          });
          const spent = minorToInr(agg._sum.amountInrMinor) ?? 0;
          const limit = Number(b.monthlyLimitInr) / 100;
          const pct = limit > 0 ? (spent / limit) * 100 : 0;
          return {
            category: b.category.name,
            monthlyLimitInr: limit,
            spentInr: spent,
            remainingInr: limit - spent,
            percentConsumed: Math.round(pct * 10) / 10,
            transactionCount: agg._count._all,
            firedThresholds: b.alerts.map((a) => ({
              threshold: Number(a.threshold),
              firedAt: a.firedAt.toISOString(),
            })),
            enabled: b.enabled,
          };
        }),
      );

      return {
        content: [
          asJsonText({
            month: yearMonth,
            timezone: 'Asia/Kolkata',
            budgets: rows.sort((a, b) => b.percentConsumed - a.percentConsumed),
          }),
        ],
      };
    },
  );

  server.registerTool(
    'budget_history',
    {
      title: 'Historical budget alerts',
      description:
        'List the most recent budget-threshold firings across all categories and months. Each row represents one push the backend sent when a threshold (80%, 100%, 110%, etc.) was crossed for the first time in that category-month.',
      inputSchema: {
        limit: z.number().int().min(1).max(200).default(50),
      },
    },
    async (args) => {
      const rows = await prisma.budgetAlertFired.findMany({
        orderBy: { firedAt: 'desc' },
        take: args.limit,
        include: {
          budget: {
            include: { category: { select: { name: true } } },
          },
        },
      });
      return {
        content: [
          asJsonText({
            count: rows.length,
            alerts: rows.map((r) => ({
              category: r.budget.category.name,
              month: r.yearMonth,
              threshold: Number(r.threshold),
              firedAt: r.firedAt.toISOString(),
            })),
          }),
        ],
      };
    },
  );
}
