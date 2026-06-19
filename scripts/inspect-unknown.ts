// One-off: fetch the full body of the most recent unknown_hdfc emails
// that match the "We're sharing this alert" marker. Used to author a
// new HDFC parser template against the real wire shape.

import { google } from 'googleapis';
import { authorizedClient } from '../src/gmail/oauth.js';
import { extractMessage } from '../src/gmail/messageBody.js';
import { prisma } from '../src/db/client.js';

async function main() {
  const rows = await prisma.emailMessage.findMany({
    where: {
      kind: 'unknown_hdfc',
      rawSnippet: { contains: 'sharing this alert' },
    },
    orderBy: { receivedAt: 'desc' },
    take: 1,
  });
  if (rows.length === 0) {
    console.log('No matching unknown_hdfc rows.');
    await prisma.$disconnect();
    return;
  }

  const auth = await authorizedClient();
  const gmail = google.gmail({ version: 'v1', auth });

  for (const r of rows) {
    console.log(`=== ${r.gmailMessageId}  (${r.receivedAt.toISOString()})`);
    console.log(`subject: ${r.rawSubject}`);
    const resp = await gmail.users.messages.get({
      userId: 'me',
      id: r.gmailMessageId,
      format: 'full',
    });
    const msg = extractMessage(resp.data);
    console.log(`from: ${msg.fromAddress}\n`);
    console.log('--- BODY ---');
    console.log(msg.body);
    console.log('--- END BODY ---');
  }

  await prisma.$disconnect();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
