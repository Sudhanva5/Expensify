// Replay the CURRENT receipt extractors over already-stored EmailReceipt
// rows, then re-run binding on anything whose amount changed.
//
// Why this has to exist: extraction is persisted at ingest and the email
// body is NOT kept on the row, so improving an extractor does nothing for
// receipts already in the table and there was no way to replay it. Three
// redBus tickets (TV8Q64078508 / TV8K83353864 / TV8K93604197) sat unbound
// for a month holding the GROSS ticket price, from before `extractRedbus`
// learned to read "Ticket Price" across a line break and subtract the
// coupon line. Today's parser gets all three right — nothing had ever
// asked it again.
//
// This is the receipt-side counterpart of scripts/backfill-vpa-merchants.ts,
// and it should be re-run after any edit to src/receipts/extractors.ts.
//
//   npx tsx scripts/reextract-receipts.ts                 # dry run (default)
//   npx tsx scripts/reextract-receipts.ts --apply         # write changes
//   npx tsx scripts/reextract-receipts.ts --all           # include BOUND rows too
//
// Scope: ORPHAN receipts only, unless --all. A bound receipt matched on an
// exact amount, so its extraction is already corroborated by a transaction;
// re-parsing it risks moving a correct row for no gain. --all exists for
// after a big extractor change, when you want to see everything.
//
// The email body comes back from the Gmail API (messages.get) since we
// don't store it. Messages deleted from the mailbox are reported and
// skipped.

import { google } from 'googleapis';
import { Prisma } from '@prisma/client';
import { prisma } from '../src/db/client.js';
import { authorizedClient } from '../src/gmail/oauth.js';
import { extractMessage } from '../src/gmail/messageBody.js';
import {
  extractReceiptFields,
  tryBindToTransaction,
} from '../src/pipeline/processReceiptEmail.js';
import { bindAllOrphanReceipts } from '../src/pipeline/bindOrphanReceipts.js';

const R = (m: bigint | null): string =>
  m === null ? 'null' : `₹${(Number(m) / 100).toFixed(2)}`;

interface Change {
  id: string;
  gmailMessageId: string;
  subject: string;
  receivedAt: Date;
  wasBound: boolean;
  oldAmount: bigint | null;
  newAmount: bigint | null;
  oldParser: string;
  newParser: string;
  oldSource: string;
  newSource: string;
  newOrderId: string | null;
}

async function main(): Promise<void> {
  const apply = process.argv.includes('--apply');
  const all = process.argv.includes('--all');

  const rows = await prisma.emailReceipt.findMany({
    where: all ? {} : { transactionId: null },
    select: {
      id: true,
      gmailMessageId: true,
      subject: true,
      source: true,
      amountInrMinor: true,
      orderId: true,
      parserVersion: true,
      fromAddress: true,
      receivedAt: true,
      transactionId: true,
    },
    orderBy: { receivedAt: 'desc' },
  });

  console.log(
    `${rows.length} receipt(s) in scope (${all ? 'ALL rows' : 'orphans only'}), ` +
      `${apply ? 'APPLY' : 'dry run — pass --apply to write'}\n`,
  );

  const auth = await authorizedClient();
  const gmail = google.gmail({ version: 'v1', auth });

  const changes: Change[] = [];
  let missing = 0;
  let unchanged = 0;

  for (const row of rows) {
    let body: string;
    let fromAddress: string | null;
    try {
      const res = await gmail.users.messages.get({
        userId: 'me',
        id: row.gmailMessageId,
        format: 'full',
      });
      const ex = extractMessage(res.data);
      body = ex.body;
      // Prefer the live header, but fall back to the stored value — the
      // extractor is routed by from-address and we must not silently
      // reroute a row just because parsing the header failed this time.
      fromAddress = ex.fromAddress ?? row.fromAddress;
    } catch (err) {
      // Usually a 404: the message was deleted from the mailbox after we
      // stored the receipt. Nothing to replay; leave the row untouched.
      missing++;
      console.warn(
        `  ! ${row.gmailMessageId} unavailable (${(err as Error).message.slice(0, 60)}) — skipped`,
      );
      continue;
    }

    const { extracted, finalSource } = extractReceiptFields({ fromAddress, body });

    const amountChanged = extracted.amountInrMinor !== row.amountInrMinor;
    const parserChanged = extracted.parserVersion !== row.parserVersion;
    const sourceChanged = finalSource !== row.source;
    if (!amountChanged && !parserChanged && !sourceChanged) {
      unchanged++;
      continue;
    }

    changes.push({
      id: row.id,
      gmailMessageId: row.gmailMessageId,
      subject: row.subject,
      receivedAt: row.receivedAt,
      wasBound: row.transactionId !== null,
      oldAmount: row.amountInrMinor,
      newAmount: extracted.amountInrMinor,
      oldParser: row.parserVersion,
      newParser: extracted.parserVersion,
      oldSource: row.source,
      newSource: finalSource,
      newOrderId: extracted.orderId,
    });

    if (apply) {
      await prisma.emailReceipt.update({
        where: { id: row.id },
        data: {
          source: finalSource,
          amountInrMinor: extracted.amountInrMinor,
          orderId: extracted.orderId,
          itemsJson: (extracted.items as unknown as Prisma.InputJsonValue) ?? Prisma.JsonNull,
          feesJson: (extracted.fees as unknown as Prisma.InputJsonValue) ?? Prisma.JsonNull,
          metaJson: (extracted.meta as unknown as Prisma.InputJsonValue) ?? Prisma.JsonNull,
          parserVersion: extracted.parserVersion,
        },
      });
    }
  }

  console.log(
    `\n${unchanged} unchanged, ${missing} no longer in Gmail, ` +
      `${changes.length} ${apply ? 'updated' : 'would change'}:\n`,
  );

  for (const c of changes) {
    const amt =
      c.oldAmount === c.newAmount
        ? `${R(c.newAmount)} (same)`
        : `${R(c.oldAmount)} → ${R(c.newAmount)}`;
    const parser = c.oldParser === c.newParser ? c.newParser : `${c.oldParser} → ${c.newParser}`;
    const src = c.oldSource === c.newSource ? '' : `  source ${c.oldSource} → ${c.newSource}`;
    console.log(`  ${amt.padEnd(26)} ${parser.padEnd(28)}${src}  "${c.subject.slice(0, 50)}"`);
  }

  // Re-extraction only matters if it lets something bind, so finish the job.
  //
  // In APPLY mode the new amounts are already on the rows, so the normal
  // sweep does the right thing. In dry-run they are NOT, and calling the
  // sweep would just re-read the old amounts and report "nothing aligned" —
  // technically true, entirely misleading. So dry-run predicts in memory
  // using each row's NEW amount instead. Either way the pairing rule is the
  // same windowed, exactly-one-candidate `tryBindToTransaction`.
  console.log('\n=== orphan binding ===');

  if (apply) {
    const sweep = await bindAllOrphanReceipts({ dryRun: false });
    for (const b of sweep.bound) {
      const tx = await prisma.transaction.findUnique({
        where: { id: b.transactionId },
        select: { occurredAt: true, merchantRaw: true, instrument: true },
      });
      console.log(
        `  ${b.source.padEnd(10)} ${R(b.amountInrMinor).padStart(12)}  →  ` +
          `${tx?.merchantRaw ?? '?'} (${tx?.instrument ?? '?'}, ${
            tx?.occurredAt.toISOString() ?? '?'
          })`,
      );
    }
    console.log(`examined ${sweep.examined} orphans, bound ${sweep.bound.length}.`);
  } else {
    let predicted = 0;
    for (const c of changes) {
      if (c.wasBound || c.newAmount === null) continue;
      const match = await tryBindToTransaction({
        amountInrMinor: c.newAmount,
        receivedAt: c.receivedAt,
        source: c.newSource,
        allowRelaxed: false,
      });
      if (match.reason !== 'amount_and_window' || !match.transactionId) continue;
      const tx = await prisma.transaction.findUnique({
        where: { id: match.transactionId },
        select: { occurredAt: true, merchantRaw: true, instrument: true },
      });
      predicted++;
      console.log(
        `  ${c.newSource.padEnd(10)} ${R(c.newAmount).padStart(12)}  →  ` +
          `${tx?.merchantRaw ?? '?'} (${tx?.instrument ?? '?'}, ${
            tx?.occurredAt.toISOString() ?? '?'
          })`,
      );
    }
    console.log(
      `${predicted} of the ${changes.length} changed row(s) would bind once written. ` +
        `Orphans whose amount does not change are unaffected — re-run ` +
        `scripts/rebind-orphan-receipts.ts for those.`,
    );
  }

  await prisma.$disconnect();
}

main().catch(async (err) => {
  console.error(err);
  await prisma.$disconnect();
  process.exit(1);
});
