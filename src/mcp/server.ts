// Remote MCP server for Expense Solver.
//
// Transport: Streamable HTTP (the modern MCP transport — single endpoint,
// stateless, JSON or SSE depending on the request).
//
// Auth modes (both work, checked in order):
//   1. Static bearer — `Authorization: Bearer <MCP_TOKEN>`. Used by
//      Claude Code / Claude Desktop, who accept a static header in their
//      config and skip the OAuth dance entirely.
//   2. OAuth bearer — bearer token issued via the /authorize → /token flow
//      and stored hashed in McpAccessToken. Used by claude.ai web's
//      custom-connector flow, which requires dynamic client registration
//      and PKCE.
//
// On unauthenticated /mcp requests we set WWW-Authenticate pointing at
// /.well-known/oauth-protected-resource so MCP clients can discover the
// OAuth metadata.
//
// Mode is intentionally STATELESS: every POST gets a fresh McpServer +
// transport pair, then they're closed when the response ends.
//
// Health endpoints mirror the main backend's split:
//   /health     — DB-free liveness probe (Railway healthcheck target)
//   /health/db  — readiness probe that pings Postgres
// If /health touched the DB and Postgres blipped, Railway would mark the
// service down. The split keeps the service alive through DB outages.

import Fastify from 'fastify';
import type { FastifyRequest, FastifyReply } from 'fastify';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { prisma } from '../db/client.js';
import { registerSpendTools } from './handlers/spend.js';
import { registerBudgetTools } from './handlers/budgets.js';
import { registerRuleTools } from './handlers/rules.js';
import { registerDebugTools } from './handlers/debug.js';
import { registerDetailTools } from './handlers/details.js';
import { oauthRoutes } from './oauth/routes.js';
import { lookupActiveToken } from './oauth/store.js';

function buildMcpServer(): McpServer {
  const server = new McpServer(
    {
      name: 'expense-solver',
      version: '0.2.0',
    },
    {
      capabilities: {
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
  registerDetailTools(server);

  return server;
}

/// Resolves the bearer token on a request, returning a tag describing
/// which auth path matched. `null` means no valid credential was found
/// — caller emits 401 with WWW-Authenticate.
type AuthOutcome =
  | { kind: 'static' }
  | { kind: 'oauth'; clientName: string | null }
  | { kind: 'reject'; reason: string };

async function authorize(req: FastifyRequest): Promise<AuthOutcome> {
  const header = req.headers['authorization'];
  if (!header || typeof header !== 'string') {
    return { kind: 'reject', reason: 'missing_authorization' };
  }
  const match = /^Bearer\s+(.+)$/.exec(header);
  if (!match) {
    return { kind: 'reject', reason: 'invalid_authorization_scheme' };
  }
  const token = match[1]!.trim();

  const staticToken = process.env['MCP_TOKEN'];
  if (staticToken && token === staticToken) {
    return { kind: 'static' };
  }

  // Fall through to the OAuth-issued-token table. lookupActiveToken bumps
  // lastUsedAt as a side effect, so we only consult the DB when the
  // static-token comparison didn't match.
  const oauthHit = await lookupActiveToken(token);
  if (oauthHit) {
    return { kind: 'oauth', clientName: oauthHit.clientName };
  }

  return { kind: 'reject', reason: 'invalid_token' };
}

/// Build the WWW-Authenticate header per RFC 9728 §5.2. The
/// `resource_metadata` parameter lets MCP clients discover the OAuth
/// flow without already knowing about this server.
function wwwAuthenticateHeader(req: FastifyRequest): string {
  const proto = (req.headers['x-forwarded-proto'] as string) || 'https';
  const host = req.headers['host'] as string;
  const base = process.env['MCP_PUBLIC_URL']?.replace(/\/$/, '') || `${proto}://${host}`;
  const metadataUrl = `${base}/.well-known/oauth-protected-resource`;
  return `Bearer realm="expense-solver", resource_metadata="${metadataUrl}"`;
}

async function reject401(req: FastifyRequest, reply: FastifyReply, error: string): Promise<void> {
  reply
    .code(401)
    .header('www-authenticate', wwwAuthenticateHeader(req))
    .send({ error });
}

async function bootstrap(): Promise<void> {
  const app = Fastify({
    logger: { level: process.env['LOG_LEVEL'] ?? 'info' },
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

  await app.register(oauthRoutes);

  // Single MCP endpoint. POST is the standard direction (client → server
  // JSON-RPC). GET / DELETE are part of the spec for SSE upgrade and
  // session termination, but stateless mode handles them inside the
  // transport — we just need to forward.
  app.all('/mcp', async (req, reply) => {
    const auth = await authorize(req);
    if (auth.kind === 'reject') {
      await reject401(req, reply, auth.reason);
      return;
    }

    // Hand the raw Node req/res over to the MCP transport. Fastify must
    // not try to write its own response on top — reply.hijack() detaches it.
    reply.hijack();

    const mcpServer = buildMcpServer();
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
    });

    reply.raw.on('close', () => {
      void transport.close().catch(() => undefined);
      void mcpServer.close().catch(() => undefined);
    });

    try {
      await mcpServer.connect(transport);
      await transport.handleRequest(req.raw, reply.raw, req.body);
    } catch (err) {
      req.log.error({ err }, '[mcp] handleRequest failed');
      if (!reply.raw.headersSent) {
        reply.raw.writeHead(500, { 'content-type': 'application/json' });
        reply.raw.end(JSON.stringify({ error: 'Internal MCP error' }));
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
