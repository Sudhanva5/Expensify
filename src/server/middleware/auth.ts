// Static-token auth for iOS endpoints. The iOS client sends
//   Authorization: Bearer <API_TOKEN>
// and we compare against the API_TOKEN env var. Single-user V1 — there's
// only one valid token.

import type { FastifyRequest, FastifyReply } from 'fastify';

export async function requireApiToken(
  req: FastifyRequest,
  reply: FastifyReply,
): Promise<void> {
  const expected = process.env['API_TOKEN'];
  if (!expected) {
    req.log.error('API_TOKEN not configured on server');
    reply.code(500).send({ error: 'API_TOKEN not configured' });
    return;
  }

  const auth = req.headers['authorization'];
  if (!auth || auth !== `Bearer ${expected}`) {
    reply.code(401).send({ error: 'Unauthorized' });
    return;
  }
  // Pass-through if matched.
}
