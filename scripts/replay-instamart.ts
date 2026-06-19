// One-off: fetch recent emails from noreply@instamart.in and push
// each through processReceiptEmail. Idempotent (gmailMessageId is
// the dedup key). Lives in scripts/ so tsx resolves project imports.

import { google } from 'googleapis';
import { authorizedClient } from '../src/gmail/oauth.js';
import { extractMessage } from '../src/gmail/messageBody.js';
import { processReceiptEmail } from '../src/pipeline/processReceiptEmail.js';
import { prisma } from '../src/db/client.js';

async function main() {
  const auth = await authorizedClient();
  const gmail = google.gmail({ version: 'v1', auth });

  const list = await gmail.users.messages.list({
    userId: 'me',
    q: 'from:instamart.in newer_than:7d',
    maxResults: 50,
  });
  const ids =
    list.data.messages?.map((m) => m.id).filter((x): x is string => !!x) ?? [];
  console.log(`Found ${ids.length} matching message(s) in the last 7 days\n`);

  for (const id of ids) {
    const resp = await gmail.users.messages.get({
      userId: 'me',
      id,
      format: 'full',
    });
    const msg = extractMessage(resp.data);
    console.log(`→ ${id}`);
    console.log(`  from:    ${msg.fromAddress}`);
    console.log(`  subject: ${msg.subject}`);
    const outcome = await processReceiptEmail(msg);
    console.log(
      `  outcome: ${JSON.stringify(outcome, (_k, v) => (typeof v === 'bigint' ? v.toString() : v))}\n`,
    );
  }

  await prisma.$disconnect();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
