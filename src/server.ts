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
import { devicesRoute } from './server/routes/devices.js';
import { transactionsRoute } from './server/routes/transactions.js';
import { budgetsRoute } from './server/routes/budgets.js';
import { rulesRoute } from './server/routes/rules.js';
import { contactsRoute } from './server/routes/contacts.js';
import { scheduleWatchRefresh } from './server/cron.js';

export async function buildServer() {
  const app = Fastify({
    logger: {
      level: process.env['LOG_LEVEL'] ?? 'info',
    },
  });

  await app.register(sensible);

  await app.register(healthRoute);
  await app.register(gmailWebhookRoute, { prefix: '/webhooks' });
  await app.register(devicesRoute, { prefix: '/devices' });
  await app.register(transactionsRoute, { prefix: '/transactions' });
  await app.register(budgetsRoute, { prefix: '/budgets' });
  await app.register(rulesRoute, { prefix: '/rules' });
  await app.register(contactsRoute, { prefix: '/contacts' });

  return app;
}

// Direct entrypoint when run via `npx tsx src/server.ts`. We compare on the
// basename so this works regardless of symlinked /tmp paths or how the tool
// chain resolves them.
const isDirectRun = process.argv[1]?.endsWith('/server.ts');
if (isDirectRun) {
  const port = Number(process.env['PORT'] ?? 3000);
  buildServer()
    .then(async (app) => {
      const addr = await app.listen({ port, host: '0.0.0.0' });
      console.log(`API listening on ${addr}`);
      scheduleWatchRefresh(app);
    })
    .catch((err) => {
      console.error(err);
      process.exit(1);
    });
}
