// Catch-up replay: walk Gmail history from the saved `lastHistoryId`
// forward and feed every message through the same pipeline the webhook
// uses. Used after a Pub/Sub gap (Postgres outage today) — Pub/Sub
// retries fall off after a few hours, so we backfill via Gmail's
// own history API which has a 7-day window.
//
//   npx tsx scripts/replay-gmail-history.ts            # uses saved historyId
//   npx tsx scripts/replay-gmail-history.ts --from N   # explicit start
//
// Idempotent — every downstream step (processGmailMessage,
// processReceiptEmail) keys on gmailMessageId and skips dupes.

import { prisma } from '../src/db/client.js';
import { authorizedClient } from '../src/gmail/oauth.js';
import {
  fetchNewMessagesSince,
  loadLastHistoryId,
  persistLatestHistoryId,
} from '../src/gmail/history.js';
import { processGmailMessage } from '../src/pipeline/processGmailMessage.js';
import { processReceiptEmail } from '../src/pipeline/processReceiptEmail.js';
import { buildCategorizeContextFromDb } from '../src/db/categorizeContext.js';
import { isReceiptSender } from '../src/receipts/extractors.js';
import { isLikelyHdfcAlert } from '../src/gmail/messageBody.js';

function getArg(name: string): string | null {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx < 0) return null;
  return process.argv[idx + 1] ?? null;
}

async function main() {
  const explicitFrom = getArg('from');
  const startId = explicitFrom ?? (await loadLastHistoryId());
  if (!startId) {
    console.error('[replay] no historyId to start from — run gmail-watch.ts to seed one first');
    process.exit(1);
  }
  console.log(`[replay] starting from historyId=${startId}`);

  const auth = await authorizedClient();
  const { messages, latestHistoryId } = await fetchNewMessagesSince(auth, startId);
  console.log(`[replay] fetched ${messages.length} new message(s); latest historyId=${latestHistoryId}`);

  const ctx = await buildCategorizeContextFromDb();

  let hdfcProcessed = 0;
  let receipts = 0;
  let skipped = 0;
  let failed = 0;
  for (const msg of messages) {
    try {
      if (isLikelyHdfcAlert(msg.fromAddress, msg.subject)) {
        const outcome = await processGmailMessage(msg, ctx);
        console.log(`  hdfc ${msg.id} → ${outcome.kind}`);
        if (outcome.kind === 'processed') hdfcProcessed++;
        else skipped++;
      } else if (isReceiptSender(msg.fromAddress)) {
        const outcome = await processReceiptEmail(msg);
        console.log(`  receipt ${msg.id} → ${outcome.kind} (${(outcome as { source?: string }).source ?? ''})`);
        if (outcome.kind === 'processed') receipts++;
        else skipped++;
      } else {
        skipped++;
      }
    } catch (err) {
      console.warn(`  ${msg.id} FAILED: ${(err as Error).message}`);
      failed++;
    }
  }

  if (latestHistoryId) {
    await persistLatestHistoryId(latestHistoryId);
    console.log(`[replay] saved latestHistoryId=${latestHistoryId}`);
  }
  console.log(`[replay] done. hdfc=${hdfcProcessed} receipts=${receipts} skipped=${skipped} failed=${failed}`);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error('[replay] fatal:', err);
    process.exit(1);
  });
