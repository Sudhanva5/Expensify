// Pipeline-debugging tools — answer "why didn't this email show up?"

import { z } from 'zod';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { prisma } from '../../db/client.js';
import { asJsonText, minorToInr } from '../formatters.js';

export function registerDebugTools(server: McpServer): void {
  server.registerTool(
    'unparsed_hdfc_emails',
    {
      title: 'HDFC emails the parser could not classify',
      description:
        'List EmailMessage rows with kind="unknown_hdfc" — HDFC alerts that didn\'t match any of the 6 known templates. These are the signal that a new template has appeared and the parser needs an update.',
      inputSchema: {
        limit: z.number().int().min(1).max(100).default(20),
      },
    },
    async (args) => {
      const rows = await prisma.emailMessage.findMany({
        where: { kind: 'unknown_hdfc' },
        orderBy: { receivedAt: 'desc' },
        take: args.limit,
      });
      return {
        content: [
          asJsonText({
            count: rows.length,
            emails: rows.map((r) => ({
              gmailMessageId: r.gmailMessageId,
              subject: r.rawSubject,
              snippet: r.rawSnippet,
              parseError: r.parseError,
              receivedAt: r.receivedAt.toISOString(),
            })),
          }),
        ],
      };
    },
  );

  server.registerTool(
    'unbound_receipts',
    {
      title: 'Receipt emails that did not bind to a transaction',
      description:
        'List EmailReceipt rows where transactionId is NULL — receipts that arrived but could not be matched to any HDFC transaction. Often signals a parser fee/total issue, a ±90 min window miss, or a source-keyword mismatch. Each row carries source, amount, parserVersion, and parseError.',
      inputSchema: {
        source: z
          .string()
          .optional()
          .describe(
            'Optional source filter: "swiggy", "instamart", "redbus", "makemytrip", "generic", etc.',
          ),
        limit: z.number().int().min(1).max(100).default(20),
      },
    },
    async (args) => {
      const rows = await prisma.emailReceipt.findMany({
        where: {
          transactionId: null,
          ...(args.source ? { source: args.source } : {}),
        },
        orderBy: { receivedAt: 'desc' },
        take: args.limit,
      });
      return {
        content: [
          asJsonText({
            count: rows.length,
            receipts: rows.map((r) => ({
              id: r.id,
              source: r.source,
              subject: r.subject,
              snippet: r.snippet,
              amountInr: minorToInr(r.amountInrMinor),
              orderId: r.orderId,
              fromAddress: r.fromAddress,
              receivedAt: r.receivedAt.toISOString(),
              parserVersion: r.parserVersion,
              parseError: r.parseError,
            })),
          }),
        ],
      };
    },
  );

  server.registerTool(
    'recent_email_messages',
    {
      title: 'Recent Gmail messages the pipeline touched',
      description:
        'List the most recent EmailMessage rows — every Gmail message the webhook has seen, including parsed transactions, skipped non-transactions, and parse failures. Filter by kind to narrow ("hdfc_upi_debit", "hdfc_cc_autopay", "hdfc_not_transaction", "unknown_hdfc", "non_hdfc").',
      inputSchema: {
        kind: z
          .string()
          .optional()
          .describe('Optional EmailMessage.kind filter.'),
        limit: z.number().int().min(1).max(100).default(20),
      },
    },
    async (args) => {
      const rows = await prisma.emailMessage.findMany({
        where: args.kind ? { kind: args.kind } : {},
        orderBy: { receivedAt: 'desc' },
        take: args.limit,
      });
      return {
        content: [
          asJsonText({
            count: rows.length,
            emails: rows.map((r) => ({
              gmailMessageId: r.gmailMessageId,
              kind: r.kind,
              subject: r.rawSubject,
              snippet: r.rawSnippet,
              parserVersion: r.parserVersion,
              parseError: r.parseError,
              receivedAt: r.receivedAt.toISOString(),
            })),
          }),
        ],
      };
    },
  );
}
