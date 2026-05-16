// One-shot backfill: walk historical emails from known receipt senders
// and run each through processReceiptEmail. Catches every Swiggy /
// Amazon / Zomato / etc. order email that arrived BEFORE this feature
// shipped, links them to the matching HDFC transaction by amount +
// timestamp, and persists EmailReceipt rows.
//
// Idempotent — processReceiptEmail() is keyed on gmailMessageId, so
// re-running is safe.
//
// Usage:
//   DATABASE_URL=... GOOGLE_OAUTH_* npx tsx scripts/backfill-receipts.ts
//
// Pass --dry-run to log what WOULD happen without writing.

import { google } from 'googleapis';
import { authorizedClient } from '../src/gmail/oauth.js';
import { extractMessage } from '../src/gmail/messageBody.js';
import { processReceiptEmail } from '../src/pipeline/processReceiptEmail.js';
import { RECEIPT_SENDER_DOMAINS } from '../src/receipts/extractors.js';
import { prisma } from '../src/db/client.js';

const DRY_RUN = process.argv.includes('--dry-run');
const LOOKBACK = process.argv.includes('--all') ? '' : 'newer_than:6m';

interface Stats {
  total: number;
  processed: number;
  duplicates: number;
  skippedNonReceipt: number;
  bound: number;
  unbound: number;
  withItems: number;
  perSource: Record<string, number>;
}

async function main() {
  const auth = await authorizedClient();
  const gmail = google.gmail({ version: 'v1', auth });

  console.log(`Backfill mode: ${DRY_RUN ? 'DRY RUN' : 'WRITE'}`);
  console.log(`Lookback: ${LOOKBACK || 'ALL TIME'}`);
  console.log(`Senders: ${RECEIPT_SENDER_DOMAINS.length} domains\n`);

  const stats: Stats = {
    total: 0,
    processed: 0,
    duplicates: 0,
    skippedNonReceipt: 0,
    bound: 0,
    unbound: 0,
    withItems: 0,
    perSource: {},
  };

  for (const domain of RECEIPT_SENDER_DOMAINS) {
    const q = ['from:' + domain, LOOKBACK].filter(Boolean).join(' ');
    let pageToken: string | undefined = undefined;
    let pageCount = 0;
    const maxPages = 5; // cap per-sender at ~500 messages

    do {
      const list = await gmail.users.messages.list({
        userId: 'me',
        q,
        maxResults: 100,
        pageToken,
      });
      const ids = list.data.messages?.map((m) => m.id).filter((x): x is string => !!x) ?? [];
      if (ids.length === 0) break;

      console.log(`[${domain}] page ${++pageCount}: ${ids.length} messages`);

      for (const id of ids) {
        stats.total++;
        try {
          const resp = await gmail.users.messages.get({
            userId: 'me',
            id,
            format: 'full',
          });
          const msg = extractMessage(resp.data);
          if (DRY_RUN) {
            console.log(`  would process ${msg.fromAddress} • ${msg.subject.slice(0, 60)}`);
            continue;
          }
          const outcome = await processReceiptEmail(msg);
          switch (outcome.kind) {
            case 'skipped_non_receipt':
              stats.skippedNonReceipt++;
              break;
            case 'duplicate':
              stats.duplicates++;
              break;
            case 'processed':
              stats.processed++;
              stats.perSource[outcome.source] = (stats.perSource[outcome.source] ?? 0) + 1;
              if (outcome.boundTransactionId) stats.bound++;
              else stats.unbound++;
              if (outcome.itemsCount > 0) stats.withItems++;
              break;
          }
        } catch (err) {
          console.error(`  error on ${id}: ${(err as Error).message.slice(0, 120)}`);
        }
      }

      pageToken = list.data.nextPageToken ?? undefined;
      if (pageCount >= maxPages) break;
    } while (pageToken);
  }

  console.log('\n' + '═'.repeat(60));
  console.log('BACKFILL SUMMARY');
  console.log('═'.repeat(60));
  console.log(`Total messages walked:      ${stats.total}`);
  console.log(`Duplicates (already had):   ${stats.duplicates}`);
  console.log(`Skipped (non-receipt):      ${stats.skippedNonReceipt}`);
  console.log(`Newly processed:            ${stats.processed}`);
  console.log(`  └─ With structured items: ${stats.withItems}`);
  console.log(`  └─ Bound to HDFC tx:      ${stats.bound}`);
  console.log(`  └─ Orphan (no match):     ${stats.unbound}`);
  console.log('\nPer-source breakdown:');
  for (const [source, count] of Object.entries(stats.perSource).sort((a, b) => b[1] - a[1])) {
    console.log(`  ${source.padEnd(20)} ${count}`);
  }
}

main()
  .catch((err) => {
    console.error(err);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
