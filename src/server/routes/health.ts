import type { FastifyInstance } from 'fastify';
import { prisma } from '../../db/client.js';

export async function healthRoute(app: FastifyInstance): Promise<void> {
  app.get('/health', async () => {
    // Cheap query to confirm DB is reachable
    await prisma.$queryRaw`SELECT 1`;
    return {
      ok: true,
      time: new Date().toISOString(),
    };
  });
}
