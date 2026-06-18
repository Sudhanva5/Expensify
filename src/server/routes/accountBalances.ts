// Account-balance read API for the iOS home screen.
//
// One endpoint: GET /account-balance returns every known balance row,
// newest-asOf first. iOS currently shows just the top entry (single-
// account V1) but the wire shape is plural so future multi-account
// users get the same response without a route version bump.

import type { FastifyInstance } from 'fastify';
import { requireApiToken } from '../middleware/auth.js';
import { listAccountBalances } from '../../db/accountBalances.js';

export async function accountBalancesRoute(app: FastifyInstance): Promise<void> {
  app.get(
    '/',
    { preHandler: requireApiToken },
    async () => {
      const rows = await listAccountBalances();
      const sorted = [...rows].sort(
        (a, b) => b.asOf.getTime() - a.asOf.getTime(),
      );
      return {
        balances: sorted.map((r) => ({
          instrument: r.instrument,
          balance_inr_minor: Number(r.balanceInrMinor),
          as_of: r.asOf.toISOString(),
          source: r.source,
          updated_at: r.updatedAt.toISOString(),
        })),
      };
    },
  );
}
