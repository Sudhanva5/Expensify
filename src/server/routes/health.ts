import type { FastifyInstance } from 'fastify';
import { prisma } from '../../db/client.js';

/// Two probes, intentionally split:
///
///   • GET /health    — LIVENESS. "Is Fastify up?" — NEVER touches the
///     DB. Railway's healthcheck hits this so a DB hiccup can't
///     cascade into the whole service being killed by the platform.
///
///   • GET /health/db — READINESS. "Is Postgres reachable?" — pings
///     the DB explicitly. Returns 503 when the DB is down.
///
/// Why split: the previous `/health` ran `SELECT 1` against Postgres.
/// When Postgres went unreachable, every healthcheck failed, Railway
/// considered the deploy unhealthy and rolled it back. Then the new
/// deploy did the same thing — a DB blip became a full app outage,
/// with /health returning 500 even though Fastify itself was fine.
///
/// With liveness decoupled, the API stays up through transient DB
/// issues; routes that *do* need the DB still return their own 500s
/// and recover the instant Postgres is back.
export async function healthRoute(app: FastifyInstance): Promise<void> {
  app.get('/health', async () => ({
    ok: true,
    time: new Date().toISOString(),
  }));

  app.get('/health/db', async (_req, reply) => {
    try {
      await prisma.$queryRaw`SELECT 1`;
      return { ok: true, db: 'reachable', time: new Date().toISOString() };
    } catch (err) {
      return reply.code(503).send({
        ok: false,
        db: 'unreachable',
        error: (err as Error).message,
        time: new Date().toISOString(),
      });
    }
  });
}
