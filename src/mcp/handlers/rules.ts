// Rule + learned-pattern inspection. Lets Claude reason about WHY a given
// row was categorized — was it an alias, a learned VPA, a user rule?

import { z } from 'zod';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { prisma } from '../../db/client.js';
import { asJsonText } from '../formatters.js';

export function registerRuleTools(server: McpServer): void {
  server.registerTool(
    'list_user_rules',
    {
      title: 'List user-authored categorization rules',
      description:
        'List user rules in priority order (highest first). Each rule has a JSONB conditions blob — direction, instrument, amountBetween, timeOfDayBetween (IST HH:MM), dayOfWeek, payeeContains, payeeRegex, vpaShape, locationWithinRadius. Defaults to enabled rules only.',
      inputSchema: {
        enabledOnly: z.boolean().default(true),
      },
    },
    async (args) => {
      const rows = await prisma.userRule.findMany({
        where: args.enabledOnly ? { enabled: true } : {},
        orderBy: [{ priority: 'desc' }, { createdAt: 'asc' }],
        include: { category: { select: { name: true } } },
      });
      return {
        content: [
          asJsonText({
            count: rows.length,
            rules: rows.map((r) => ({
              id: r.id,
              name: r.name,
              priority: r.priority,
              enabled: r.enabled,
              category: r.category.name,
              defaultConfidence: Number(r.defaultConfidence),
              hitCount: r.hitCount,
              conditions: r.conditions,
              createdAt: r.createdAt.toISOString(),
              updatedAt: r.updatedAt.toISOString(),
            })),
          }),
        ],
      };
    },
  );

  server.registerTool(
    'list_vpa_patterns',
    {
      title: 'List learned VPA → category bindings',
      description:
        'List VPA patterns — UPI handles the user has confirmed as belonging to a particular category. 1-hit threshold (every future debit to that VPA auto-tags at high confidence). Ordered by most recently confirmed.',
      inputSchema: {
        category: z
          .string()
          .optional()
          .describe('Filter to one category name, e.g. "Food".'),
        limit: z.number().int().min(1).max(500).default(100),
      },
    },
    async (args) => {
      const rows = await prisma.vpaPattern.findMany({
        where: args.category ? { category: { name: args.category } } : {},
        orderBy: { lastConfirmedAt: 'desc' },
        take: args.limit,
        include: { category: { select: { name: true } } },
      });
      return {
        content: [
          asJsonText({
            count: rows.length,
            patterns: rows.map((r) => ({
              vpa: r.vpa,
              category: r.category.name,
              merchantName: r.merchantName,
              hitCount: r.hitCount,
              firstSeenAt: r.firstSeenAt.toISOString(),
              lastConfirmedAt: r.lastConfirmedAt.toISOString(),
            })),
          }),
        ],
      };
    },
  );

  server.registerTool(
    'list_merchant_patterns',
    {
      title: 'List learned merchant-name patterns',
      description:
        'List merchant patterns keyed on merchantNormalized. 3-hit threshold required before autoTagActive flips to true. Use the autoTagOnly filter to see only the ones that currently auto-tag.',
      inputSchema: {
        autoTagOnly: z
          .boolean()
          .default(false)
          .describe('When true, only return patterns where autoTagActive=true.'),
        category: z.string().optional(),
        limit: z.number().int().min(1).max(500).default(100),
      },
    },
    async (args) => {
      const rows = await prisma.merchantPattern.findMany({
        where: {
          ...(args.autoTagOnly ? { autoTagActive: true } : {}),
          ...(args.category ? { category: { name: args.category } } : {}),
        },
        orderBy: { lastConfirmedAt: 'desc' },
        take: args.limit,
        include: { category: { select: { name: true } } },
      });
      return {
        content: [
          asJsonText({
            count: rows.length,
            patterns: rows.map((r) => ({
              merchant: r.merchantNormalized,
              category: r.category.name,
              hitCount: r.hitCount,
              autoTagActive: r.autoTagActive,
              firstSeenAt: r.firstSeenAt.toISOString(),
              lastConfirmedAt: r.lastConfirmedAt.toISOString(),
            })),
          }),
        ],
      };
    },
  );
}
