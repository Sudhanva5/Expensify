// Fastify HTTP server. Two responsibilities in V1:
//   1. Receive Pub/Sub push notifications from Gmail (/webhooks/gmail)
//   2. Serve the iOS app: register device, post location, list review queue,
//      tag a transaction, manage budgets/goals/rules.
//
// Auth model: single-user, static API token. Pub/Sub uses Google's signed JWT.

import Fastify from 'fastify';
import sensible from '@fastify/sensible';
import { gmailWebhookRoute } from './server/routes/gmailWebhook.js';
import { healthRoute } from './server/routes/health.js';

export async function buildServer() {
  const app = Fastify({
    logger: {
      level: process.env['LOG_LEVEL'] ?? 'info',
    },
  });

  await app.register(sensible);

  await app.register(healthRoute);
  await app.register(gmailWebhookRoute, { prefix: '/webhooks' });

  return app;
}

// Direct entrypoint when run via `npx tsx src/server.ts`. We compare on the
// basename so this works regardless of symlinked /tmp paths or how the tool
// chain resolves them.
const isDirectRun = process.argv[1]?.endsWith('/server.ts');
if (isDirectRun) {
  const port = Number(process.env['PORT'] ?? 3000);
  buildServer()
    .then((app) => app.listen({ port, host: '0.0.0.0' }))
    .then((addr) => console.log(`API listening on ${addr}`))
    .catch((err) => {
      console.error(err);
      process.exit(1);
    });
}
