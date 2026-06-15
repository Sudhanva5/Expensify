// Admin surface for the iOS Diagnostics screen to inspect and revoke
// MCP-issued OAuth tokens.
//
// Bearer-authed via the main backend's API_TOKEN (the existing iOS
// token), NOT the MCP_TOKEN. That keeps the iOS app's auth model
// unchanged — one bearer for everything iOS does.
//
// We read/write the McpAccessToken + McpOAuthClient tables directly
// (shared Postgres) instead of proxying through the MCP service. The
// MCP service is a runtime client of those tables; the main backend
// administers them.
//
// /mcp-admin/health does an actual TCP ping at MCP_PUBLIC_URL/health
// so the iOS UI can show online/offline with real evidence, not just
// "this service is in the DB". 2s timeout — DiagnosticsView retries
// on user pull-to-refresh.

import type { FastifyInstance } from 'fastify';
import { prisma } from '../../db/client.js';
import { requireApiToken } from '../middleware/auth.js';

interface RevokeParams {
  id: string;
}

export async function mcpAdminRoute(app: FastifyInstance): Promise<void> {
  app.get('/health', { preHandler: requireApiToken }, async (_req, reply) => {
    const url = process.env['MCP_PUBLIC_URL'];
    if (!url) {
      reply.code(500);
      return { ok: false, error: 'MCP_PUBLIC_URL not configured' };
    }
    const target = `${url.replace(/\/$/, '')}/health`;
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 2000);
    try {
      const res = await fetch(target, { signal: ctrl.signal });
      const body = (await res.json()) as { ok?: boolean; service?: string };
      return {
        ok: res.ok && body.ok === true,
        url,
        service: body.service ?? null,
        statusCode: res.status,
        checkedAt: new Date().toISOString(),
      };
    } catch (err) {
      return {
        ok: false,
        url,
        error: (err as Error).message,
        checkedAt: new Date().toISOString(),
      };
    } finally {
      clearTimeout(timer);
    }
  });

  app.get('/tokens', { preHandler: requireApiToken }, async () => {
    const rows = await prisma.mcpAccessToken.findMany({
      orderBy: { issuedAt: 'desc' },
      include: {
        client: {
          select: { clientName: true, redirectUris: true, createdAt: true },
        },
      },
    });
    return {
      count: rows.length,
      tokens: rows.map((r) => ({
        id: r.id,
        // Never expose tokenHash — it's a server-only artifact. The iOS UI
        // gets enough to render the row (label, when, last-used, revoked).
        clientName: r.label ?? r.client.clientName ?? null,
        clientId: r.clientId,
        scope: r.scope,
        issuedAt: r.issuedAt.toISOString(),
        expiresAt: r.expiresAt?.toISOString() ?? null,
        lastUsedAt: r.lastUsedAt?.toISOString() ?? null,
        revokedAt: r.revokedAt?.toISOString() ?? null,
      })),
    };
  });

  app.delete<{ Params: RevokeParams }>(
    '/tokens/:id',
    { preHandler: requireApiToken },
    async (req, reply) => {
      try {
        const row = await prisma.mcpAccessToken.update({
          where: { id: req.params.id },
          data: { revokedAt: new Date() },
        });
        return { ok: true, id: row.id, revokedAt: row.revokedAt };
      } catch {
        reply.code(404);
        return { ok: false, error: 'token_not_found' };
      }
    },
  );
}
