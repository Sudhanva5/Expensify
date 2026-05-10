// Register (or refresh) a Gmail watch against your Pub/Sub topic.
// Watches expire every 7 days — run this from a cron every ~6 days in prod.
//
// Prereqs:
//   - You've completed scripts/gmail-auth.ts (refresh token in DB)
//   - .env has GOOGLE_PUBSUB_TOPIC=projects/<gcp-project>/topics/<topic>
//   - The Gmail-API-push service account has the Pub/Sub Publisher role on
//     the topic (gmail-api-push@system.gserviceaccount.com)
//
// Run: npx tsx scripts/gmail-watch.ts

import { authorizedClient } from '../src/gmail/oauth.js';
import { registerWatch } from '../src/gmail/watch.js';
import { prisma } from '../src/db/client.js';

async function main() {
  const topicName = process.env['GOOGLE_PUBSUB_TOPIC'];
  if (!topicName) {
    throw new Error('GOOGLE_PUBSUB_TOPIC not set in .env');
  }

  const auth = await authorizedClient();
  const { historyId, expirationMs } = await registerWatch(auth, { topicName });

  const expires = new Date(expirationMs);
  console.log(`✓ Watch registered.`);
  console.log(`  starting historyId: ${historyId}`);
  console.log(`  expires:            ${expires.toISOString()} (${daysUntil(expires)} days)`);
  await prisma.$disconnect();
}

function daysUntil(d: Date): string {
  const ms = d.getTime() - Date.now();
  return (ms / (1000 * 60 * 60 * 24)).toFixed(2);
}

main().catch(async (err) => {
  console.error(err);
  await prisma.$disconnect();
  process.exit(1);
});
