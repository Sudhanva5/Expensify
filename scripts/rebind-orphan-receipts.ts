// One-off backfill for receipts orphaned before the reverse bind existed.
//
// Until now, binding only ran at receipt-ingest time, so any merchant that
// emailed faster than HDFC produced a permanently unbound receipt — the
// redBus ticket that arrived 21 seconds before its ₹1355 debit alert being
// the case that surfaced it.
//
// Reuses `tryBindToTransaction` via bindAllOrphanReceipts(), so every guard
// (exact amount, source↔merchant keyword alignment, non-P2P, exactly-one-
// aligned-candidate) applies exactly as it does on the live path. Nothing
// here is a looser match than the pipeline would make on its own.
//
//   npx tsx scripts/rebind-orphan-receipts.ts            # dry run (default)
//   npx tsx scripts/rebind-orphan-receipts.ts --apply    # write the binds
//
// Idempotent: already-bound receipts are not selected, and the write is
// guarded on transactionId still being null.

import { prisma } from '../src/db/client.js';
import { bindAllOrphanReceipts } from '../src/pipeline/bindOrphanReceipts.js';

function rupees(minor: bigint): string {
  return `₹${(Number(minor) / 100).toLocaleString('en-IN', { minimumFractionDigits: 2 })}`;
}

async function main(): Promise<void> {
  const apply = process.argv.includes('--apply');

  const totalOrphans = await prisma.emailReceipt.count({ where: { transactionId: null } });
  const bindable = await prisma.emailReceipt.count({
    where: { transactionId: null, amountInrMinor: { not: null } },
  });

  console.log(
    `${totalOrphans} orphan receipts, ${bindable} with an extractable amount (the rest can never satisfy the exact-amount guard)`,
  );
  console.log(apply ? 'mode: APPLY — writing binds\n' : 'mode: dry run (pass --apply to write)\n');

  const result = await bindAllOrphanReceipts({ dryRun: !apply });

  if (result.bound.length === 0) {
    console.log(`examined ${result.examined}, nothing aligned to a transaction.`);
    await prisma.$disconnect();
    return;
  }

  // Print alongside the transaction so a human can eyeball each pairing
  // before committing to --apply.
  for (const b of result.bound) {
    const [tx, receipt] = await Promise.all([
      prisma.transaction.findUnique({
        where: { id: b.transactionId },
        select: { occurredAt: true, merchantRaw: true, merchantNormalized: true, instrument: true },
      }),
      prisma.emailReceipt.findUnique({
        where: { id: b.receiptId },
        select: { receivedAt: true, subject: true },
      }),
    ]);
    // The gap is the thing to eyeball. A few minutes is the merchant and
    // the bank describing one event; days apart means two unrelated
    // same-amount orders got paired by the relaxed pass.
    const gap =
      tx && receipt
        ? `${Math.round(
            Math.abs(tx.occurredAt.getTime() - receipt.receivedAt.getTime()) / 60000,
          )}min`
        : '?';
    console.log(
      `  ${b.source.padEnd(10)} ${rupees(b.amountInrMinor).padStart(12)}  →  ` +
        `${tx?.merchantRaw ?? '?'} (${tx?.instrument ?? '?'}, ${
          tx?.occurredAt.toISOString() ?? '?'
        })  gap ${gap}  [${b.reason}]`,
    );
  }

  console.log(
    `\nexamined ${result.examined}, ${apply ? 'bound' : 'would bind'} ${result.bound.length}.`,
  );
  await prisma.$disconnect();
}

main().catch(async (err) => {
  console.error(err);
  await prisma.$disconnect();
  process.exit(1);
});
