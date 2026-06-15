// Remote MCP server for Expense Solver.
//
// Transport: Streamable HTTP (the modern MCP transport — single endpoint,
// stateless, JSON or SSE depending on the request). Authenticated with a
// static bearer token (`MCP_TOKEN` env). Runs as its own Railway service
// alongside the main backend, sharing the same Postgres via Prisma.
//
// Mode is intentionally STATELESS: every POST gets a fresh McpServer +
// transport pair, then they're closed when the response ends. All tools
// here are read-only, so there's no session state to thread across
// requests. Stateless mode is also the simplest thing to operate (no
// session map to GC, no broken-pipe bookkeeping).
//
// Health endpoints mirror the main backend's split:
//   /health     — DB-free liveness probe (Railway healthcheck target)
//   /health/db  — readiness probe that pings Postgres
// If /health touched the DB and Postgres blipped, Railway would mark the
// service down and the next deploy would fail too. The split keeps the
// service alive through transient DB outages.

import Fastify from 'fastify';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { prisma } from '../db/client.js';
import { registerSpendTools } from './handlers/spend.js';
import { registerBudgetTools } from './handlers/budgets.js';
import { registerRuleTools } from './handlers/rules.js';
import { registerDebugTools } from './handlers/debug.js';

function buildMcpServer(): McpServer {
  const server = new McpServer(
    {
      name: 'expense-solver',
      version: '0.1.0',
    },
    {
      capabilities: {
        // Tools only — no prompts, no resources for V1. Adding either later
        // means re-declaring here AND updating the transport mode if any of
        // them carry state.
        tools: {},
      },
      instructions:
        'Personal-finance MCP for the Expense Solver app. All tools are read-only against a single-user Postgres database. Amounts are INR rupees unless noted. Dates default to IST (Asia/Kolkata). Use search_merchant for any "did I pay X" question — bank merchant names are messy, substring matching is more forgiving than equality.',
    },
  );

  registerSpendTools(server);
  registerBudgetTools(server);
  registerRuleTools(server);
  registerDebugTools(server);

  return server;
}

async function bootstrap(): Promise<void> {
  const app = Fastify({
    logger: { level: process.env['LOG_LEVEL'] ?? 'info' },
    // Fastify defaults to a 1 MiB body limit. MCP requests are small JSON-RPC
    // envelopes; this is plenty.
  });

  app.get('/health', async () => ({
    ok: true,
    service: 'mcp',
    time: new Date().toISOString(),
  }));

  app.get('/health/db', async (_req, reply) => {
    try {
      await prisma.$queryRaw`SELECT 1`;
      return { ok: true };
    } catch (err) {
      reply.code(503);
      return { ok: false, error: (err as Error).message };
    }
  });

  // Single MCP endpoint. POST is the standard direction (client → server
  // JSON-RPC). GET / DELETE are part of the spec for SSE upgrade and
  // session termination, but stateless mode rejects them cleanly via
  // the transport's own handling — we just need to forward.
  app.all('/mcp', async (req, reply) => {
    const expected = process.env['MCP_TOKEN'];
    if (!expected) {
      req.log.error('MCP_TOKEN not configured on server');
      reply.code(500).send({ error: 'MCP_TOKEN not configured' });
      return;
    }

    const auth = req.headers['authorization'];
    if (auth !== `Bearer ${expected}`) {
      reply.code(401).send({ error: 'Unauthorized' });
      return;
    }

    // Hand the raw Node req/res over to the MCP transport. Fastify must not
    // try to write its own response on top — reply.hijack() detaches it.
    reply.hijack();

    const mcpServer = buildMcpServer();
    const transport = new StreamableHTTPServerTransport({
      // No session id → stateless mode. Each request is independent.
      sessionIdGenerator: undefined,
    });

    // When the client disconnects (or the response finishes naturally), tear
    // down the per-request server + transport pair so we don't leak Prisma
    // connections or event listeners.
    reply.raw.on('close', () => {
      void transport.close().catch(() => {});
      void mcpServer.close().catch(() => {});
    });

    try {
      await mcpServer.connect(transport);
      await transport.handleRequest(req.raw, reply.raw, req.body);
    } catch (err) {
      req.log.error({ err }, '[mcp] handleRequest failed');
      if (!reply.raw.headersSent) {
        reply.raw.writeHead(500, { 'content-type': 'application/json' });
        reply.raw.end(
          JSON.stringify({ error: 'Internal MCP error' }),
        );
      } else {
        reply.raw.end();
      }
    }
  });

  const port = Number(process.env['PORT'] ?? 3001);
  const addr = await app.listen({ port, host: '0.0.0.0' });
  console.log(`[mcp] expense-solver MCP server listening on ${addr}`);
}

const isDirectRun = process.argv[1]?.endsWith('/mcp/server.ts');
if (isDirectRun) {
  bootstrap().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
