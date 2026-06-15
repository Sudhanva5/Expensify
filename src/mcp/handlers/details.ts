// Deep-detail tools — full transaction join, receipt browsing, tag/goal
// inspection. These complement the "where did my money go" surface in
// spend.ts with the "drill into one row" path.

import { z } from 'zod';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { prisma } from '../../db/client.js';
import { asJsonText, minorToInr } from '../formatters.js';
import {
  INCLUDE_VALUES,
  expandTransaction,
  expandReceipt,
  type Include,
} from '../expand.js';

const ALL_INCLUDES = new Set<Include>(INCLUDE_VALUES);

export function registerDetailTools(server: McpServer): void {
  server.registerTool(
    'get_transaction',
    {
      title: 'Get one transaction with full detail',
      description:
        'Fetch a single transaction by id with every available join eagerly loaded: bound receipts (Swiggy / MMT / redBus line items + fees), nearby-Places suggestions, GPS + locationStatus, FX block, raw HDFC subject/snippet. Use after list_transactions / search_merchant to drill into one specific row the user wants explained.',
      inputSchema: {
        id: z.string().describe('Transaction id (the cuid surfaced by list_transactions).'),
      },
    },
    async (args) => {
      const row = await prisma.transaction.findUnique({
        where: { id: args.id },
        include: {
          category: { select: { name: true } },
          receipts: { orderBy: { receivedAt: 'desc' } },
        },
      });
      if (!row) {
        return {
          content: [asJsonText({ error: 'not_found', id: args.id })],
        };
      }
      return {
        content: [asJsonText(expandTransaction(row, ALL_INCLUDES))],
      };
    },
  );

  server.registerTool(
    'recent_receipts',
    {
      title: 'Recent receipt emails with full line items',
      description:
        'List the most recent receipts the binder has parsed (bound to a transaction or orphan). Each row carries the full Swiggy / Instamart / redBus / MakeMyTrip / generic items + fees + meta JSON exactly as the per-source parser produced it. Useful for "what did I order at this restaurant?" or "what bus did I book?" questions.',
      inputSchema: {
        source: z
          .string()
          .optional()
          .describe(
            'Filter to one source string: "swiggy", "instamart", "redbus", "makemytrip", "generic", etc.',
          ),
        boundOnly: z
          .boolean()
          .default(false)
          .describe(
            'When true, return only receipts that bound to a transaction. Defaults to false (orphans included).',
          ),
        limit: z.number().int().min(1).max(100).default(20),
      },
    },
    async (args) => {
      const rows = await prisma.emailReceipt.findMany({
        where: {
          ...(args.source ? { source: args.source } : {}),
          ...(args.boundOnly ? { transactionId: { not: null } } : {}),
        },
        orderBy: { receivedAt: 'desc' },
        take: args.limit,
        include: {
          transaction: {
            select: {
              id: true,
              occurredAt: true,
              merchantNormalized: true,
              merchantRaw: true,
              amountInrMinor: true,
            },
          },
        },
      });
      return {
        content: [
          asJsonText({
            count: rows.length,
            receipts: rows.map((r) => ({
              ...expandReceipt(r),
              transaction: r.transaction
                ? {
                    id: r.transaction.id,
                    occurredAt: r.transaction.occurredAt.toISOString(),
                    merchant:
                      r.transaction.merchantNormalized ||
                      r.transaction.merchantRaw,
                    amountInr: minorToInr(r.transaction.amountInrMinor),
                  }
                : null,
            })),
          }),
        ],
      };
    },
  );

  server.registerTool(
    'list_tags',
    {
      title: 'List user-created tags + their usage counts',
      description:
        'List every Tag row with how many transactions carry it. V1 ships without a tagging UI in iOS, so this may be empty — surface that as a known-empty state instead of hallucinating tags.',
      inputSchema: {},
    },
    async () => {
      const tags = await prisma.tag.findMany({
        include: {
          _count: { select: { transactions: true } },
        },
        orderBy: { name: 'asc' },
      });
      return {
        content: [
          asJsonText({
            count: tags.length,
            tags: tags.map((t) => ({
              id: t.id,
              name: t.name,
              transactionCount: t._count.transactions,
            })),
          }),
        ],
      };
    },
  );

  server.registerTool(
    'list_goals',
    {
      title: 'List savings / spending goals',
      description:
        'List every Goal row — name, target INR amount, deadline. Goals are a V1 schema feature without an iOS surface yet, so this may be empty.',
      inputSchema: {},
    },
    async () => {
      const goals = await prisma.goal.findMany({
        orderBy: { deadline: 'asc' },
      });
      return {
        content: [
          asJsonText({
            count: goals.length,
            goals: goals.map((g) => ({
              id: g.id,
              name: g.name,
              targetInr: Number(g.targetAmountInr) / 100,
              deadline: g.deadline.toISOString(),
              createdAt: g.createdAt.toISOString(),
            })),
          }),
        ],
      };
    },
  );

  server.registerTool(
    'list_instruments',
    {
      title: 'Distinct accounts + cards seen in transactions',
      description:
        'Returns every unique `instrument` value present in transactions (e.g. "account_5264", "card_3328", "card_2668") with the number of transactions on each and the most recent occurrence. Lets the LLM disambiguate "spend on my HDFC credit card" from "spend on my account".',
      inputSchema: {},
    },
    async () => {
      const grouped = await prisma.transaction.groupBy({
        by: ['instrument'],
        _count: { _all: true },
        _max: { occurredAt: true },
      });
      return {
        content: [
          asJsonText({
            count: grouped.length,
            instruments: grouped
              .map((g) => ({
                instrument: g.instrument,
                transactionCount: g._count._all,
                lastUsedAt: g._max.occurredAt?.toISOString() ?? null,
              }))
              .sort((a, b) => b.transactionCount - a.transactionCount),
          }),
        ],
      };
    },
  );
}
