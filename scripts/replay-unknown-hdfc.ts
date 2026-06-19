// Replay historical unknown_hdfc rows through the current parser
// dispatcher. Useful right after shipping a new template — the
// rows that landed before the parser update are stuck as
// "unknown_hdfc" forever otherwise.
//
// Strategy:
//   1. Find every EmailMessage with kind="unknown_hdfc"
//      (optionally filtered by snippet).
//   2. Delete the EmailMessage row (so recordEmailMessage's unique
//      constraint doesn't fire on re-insert).
//   3. Fetch the full message body from Gmail.
//   4. Run through processGmailMessage with a freshly-built
//      CategorizeContext.
//   5. Log the outcome per row.
//
// Idempotent — re-running won't double-insert. Run with --filter to
// limit to a substring of the snippet (e.g. "sharing this alert").

import { google } from 'googleapis';
import { authorizedClient } from '../src/gmail/oauth.js';
import { extractMessage } from '../src/gmail/messageBody.js';
import { processGmailMessage } from '../src/pipeline/processGmailMessage.js';
import { buildCategorizeContextFromDb } from '../src/db/categorizeContext.js';
import { prisma } from '../src/db/client.js';

async function main() {
  const filterIdx = process.argv.indexOf('--filter');
  const filter =
    filterIdx >= 0 && process.argv[filterIdx + 1]
      ? process.argv[filterIdx + 1]
      : null;

  const rows = await prisma.emailMessage.findMany({
    where: {
      kind: 'unknown_hdfc',
      ...(filter ? { rawSnippet: { contains: filter } } : {}),
    },
    orderBy: { receivedAt: 'desc' },
  });
  console.log(
    `Found ${rows.length} unknown_hdfc row(s)${filter ? ` matching "${filter}"` : ''}\n`,
  );
  if (rows.length === 0) {
    await prisma.$disconnect();
    return;
  }

  const auth = await authorizedClient();
  const gmail = google.gmail({ version: 'v1', auth });
  const ctx = await buildCategorizeContextFromDb();

  let processed = 0;
  let stillUnknown = 0;
  let other = 0;

  for (const row of rows) {
    console.log(`→ ${row.gmailMessageId}  (${row.receivedAt.toISOString()})`);
    console.log(`  subject: ${row.rawSubject}`);
    try {
      // Drop the stale unknown_hdfc EmailMessage row first so the
      // re-process's recordEmailMessage can insert fresh.
      await prisma.emailMessage.delete({ where: { id: row.id } });

      const resp = await gmail.users.messages.get({
        userId: 'me',
        id: row.gmailMessageId,
        format: 'full',
      });
      const msg = extractMessage(resp.data);
      const outcome = await processGmailMessage(msg, ctx);
      console.log(`  outcome: ${outcome.kind}`);
      if (outcome.kind === 'processed') processed++;
      else if (outcome.kind === 'parse_failed') stillUnknown++;
      else other++;
    } catch (err) {
      console.log(`  ERR: ${(err as Error).message}`);
    }
    console.log();
  }

  console.log(
    `\nDone — processed=${processed}, still_unknown=${stillUnknown}, other=${other}`,
  );
  await prisma.$disconnect();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
