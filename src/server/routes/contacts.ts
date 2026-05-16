// Google-contacts lookup endpoint. The iOS app calls this with a VPA
// (and optionally the raw merchant text) when its local CNContactStore
// has no match — the backend tries the cached People API snapshot
// instead. Returns a display name + photo URL or 204.
//
//   GET /contacts/google-lookup?vpa=...&merchantRaw=...
//   POST /contacts/sync      — kick a fresh People API pull
//
// Sync is gated behind the same Bearer token as everything else.
// Single-user V1; the row count is small (hundreds) so a re-sync is
// cheap and runs synchronously inside the request.

import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { requireApiToken } from '../middleware/auth.js';
import { authorizedClient } from '../../gmail/oauth.js';
import { lookupByVpa, syncGoogleContacts } from '../../services/googleContacts.js';

const querySchema = z.object({
  vpa: z.string().max(120).optional(),
  merchantRaw: z.string().max(200).optional(),
});

export async function contactsRoute(app: FastifyInstance): Promise<void> {
  app.get('/google-lookup', { preHandler: requireApiToken }, async (req, reply) => {
    const parsed = querySchema.safeParse(req.query);
    if (!parsed.success) {
      return reply.code(400).send({ error: 'Invalid query', details: parsed.error.format() });
    }
    if (!parsed.data.vpa && !parsed.data.merchantRaw) {
      return reply.code(400).send({ error: 'vpa or merchantRaw required' });
    }
    const hit = await lookupByVpa({
      vpa: parsed.data.vpa ?? null,
      merchantRaw: parsed.data.merchantRaw ?? null,
    });
    if (!hit) return reply.code(204).send();
    return {
      resource_name: hit.resourceName,
      display_name: hit.displayName,
      photo_url: hit.photoUrl,
      matched_on: hit.matchedOn,
    };
  });

  app.post('/sync', { preHandler: requireApiToken }, async (req, reply) => {
    try {
      const auth = await authorizedClient();
      const result = await syncGoogleContacts(auth);
      return { ok: true, fetched: result.fetched, saved: result.saved };
    } catch (err) {
      req.log.error({ err }, 'google contacts sync failed');
      return reply.code(500).send({
        error: 'sync_failed',
        message: (err as Error).message,
      });
    }
  });
}
