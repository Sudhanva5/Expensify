// Remove EmailReceipt rows that are marketing, feedback, or account noise
// rather than records of a purchase.
//
// `isReceiptSender()` matches on domain alone, so before the gate in
// processReceiptEmail existed every mail from an allowlisted merchant became
// a row: perfume ads, price-drop blasts, feedback surveys, OTPs. 331 of 404
// rows were unbound, and six of them held an amount the universal extractor
// had invented out of ad copy — including a ₹850 from "Here's how you can
// get a FREE bus ticket! 👇", which is one coincidence away from binding to
// a real ₹850 debit.
//
//   npx tsx scripts/prune-marketing-receipts.ts            # dry run (default)
//   npx tsx scripts/prune-marketing-receipts.ts --apply    # DELETES rows
//
// DESTRUCTIVE with --apply. Two guards on what it will touch:
//   • the row must be classified marketing by detectMarketingReceipt(), the
//     same predicate the live pipeline uses, and
//   • the row must be UNBOUND. A bound receipt is corroborated by a real
//     transaction, which outranks any opinion this predicate has.
// Every deleted email is still in Gmail, so a misjudgement costs a re-ingest,
// not the data.

import { prisma } from '../src/db/client.js';
import { detectMarketingReceipt } from '../src/receipts/marketing.js';

async function main(): Promise<void> {
  const apply = process.argv.includes('--apply');

  const rows = await prisma.emailReceipt.findMany({
    select: {
      id: true,
      subject: true,
      fromAddress: true,
      amountInrMinor: true,
      transactionId: true,
      receivedAt: true,
      source: true,
    },
    orderBy: { receivedAt: 'desc' },
  });

  const bound = rows.filter((r) => r.transactionId !== null);
  const doomed = rows.filter(
    (r) => r.transactionId === null && detectMarketingReceipt(r.fromAddress, r.subject).isMarketing,
  );

  // Safety report, not decoration: a bound receipt flagged as marketing means
  // the predicate is wrong and the run should be abandoned, not applied.
  const contradictions = bound.filter(
    (r) => detectMarketingReceipt(r.fromAddress, r.subject).isMarketing,
  );
  console.log(`${rows.length} receipts total, ${bound.length} bound.`);
  if (contradictions.length > 0) {
    console.error(
      `\nABORTING: ${contradictions.length} BOUND receipt(s) classify as marketing, so the ` +
        `predicate is unsafe. Fix src/receipts/marketing.ts before pruning.`,
    );
    for (const c of contradictions) console.error(`  "${c.subject}"`);
    await prisma.$disconnect();
    process.exit(1);
  }
  console.log('no bound receipt classifies as marketing — predicate is safe to apply.\n');

  console.log(
    `${doomed.length} unbound marketing row(s) ${apply ? 'being deleted' : 'would be deleted'}:`,
  );

  const withAmount = doomed.filter((r) => r.amountInrMinor !== null);
  if (withAmount.length > 0) {
    console.log(`\n  ...of which ${withAmount.length} carry a bogus extracted amount:`);
    for (const r of withAmount) {
      console.log(
        `    ₹${(Number(r.amountInrMinor) / 100).toFixed(2).padStart(9)}  "${r.subject.slice(0, 62)}"`,
      );
    }
  }

  const byReason = new Map<string, number>();
  for (const r of doomed) {
    const d = detectMarketingReceipt(r.fromAddress, r.subject);
    const k = `${d.reason}: ${d.matched?.toLowerCase()}`;
    byReason.set(k, (byReason.get(k) ?? 0) + 1);
  }
  console.log('\n  grouped by what matched:');
  for (const [k, v] of [...byReason.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`    ${String(v).padStart(3)}x  ${k}`);
  }

  if (!apply) {
    console.log('\ndry run — nothing deleted. Pass --apply to delete.');
    await prisma.$disconnect();
    return;
  }

  // Re-assert the unbound condition in the WHERE clause. Between the read
  // above and this write, the orphan sweep may have bound one of these rows;
  // if so it is no longer ours to delete.
  const result = await prisma.emailReceipt.deleteMany({
    where: { id: { in: doomed.map((r) => r.id) }, transactionId: null },
  });
  console.log(`\ndeleted ${result.count} row(s).`);
  await prisma.$disconnect();
}

main().catch(async (err) => {
  console.error(err);
  await prisma.$disconnect();
  process.exit(1);
});
