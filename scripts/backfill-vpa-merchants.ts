// Re-sync Transaction.vpaGateway / Transaction.vpaMerchant from the VPA.
//
// These columns are written at ingest by upsertTransaction, so this script
// exists for two cases:
//   1. Backfilling rows that pre-date the columns.
//   2. Re-syncing the whole table after a change to decodeVpaMerchant —
//      persisting the decode means decoder improvements do NOT apply
//      retroactively on their own. Run this after touching vpaMerchant.ts.
//
// Idempotent and re-runnable: it recomputes every row and only writes the
// ones whose decode actually changed.
//
//   npx tsx scripts/backfill-vpa-merchants.ts            # dry run
//   npx tsx scripts/backfill-vpa-merchants.ts --apply

import { prisma } from '../src/db/client.js';
import { decodeVpaMerchant } from '../src/categorize/vpaMerchant.js';

interface Change {
  id: string;
  vpa: string;
  fromGateway: string | null;
  toGateway: string | null;
  fromMerchant: string | null;
  toMerchant: string | null;
}

async function main(): Promise<void> {
  const apply = process.argv.includes('--apply');

  const rows = await prisma.transaction.findMany({
    where: { vpa: { not: null } },
    select: { id: true, vpa: true, vpaGateway: true, vpaMerchant: true },
  });

  const changes: Change[] = [];
  for (const r of rows) {
    if (!r.vpa) continue;
    const decoded = decodeVpaMerchant(r.vpa);
    const toGateway = decoded?.gateway ?? null;
    const toMerchant = decoded?.merchant ?? null;
    if (toGateway === r.vpaGateway && toMerchant === r.vpaMerchant) continue;
    changes.push({
      id: r.id,
      vpa: r.vpa,
      fromGateway: r.vpaGateway,
      toGateway,
      fromMerchant: r.vpaMerchant,
      toMerchant,
    });
  }

  console.log(`rows with a VPA: ${rows.length}`);
  console.log(`rows whose decode changed: ${changes.length}`);

  const decodedNow = rows.filter((r) => r.vpa && decodeVpaMerchant(r.vpa));
  console.log(`rows that decode to something: ${decodedNow.length}`);

  if (changes.length === 0) {
    console.log('nothing to do — already in sync');
    await prisma.$disconnect();
    return;
  }

  const preview = changes.slice(0, 15);
  console.log(`\n${apply ? 'APPLYING' : 'DRY RUN'} — first ${preview.length}:`);
  for (const c of preview) {
    console.log(
      `  ${c.vpa.padEnd(36)} gateway ${String(c.fromGateway).padEnd(10)} → ${String(c.toGateway).padEnd(10)} | merchant ${String(c.fromMerchant).padEnd(14)} → ${c.toMerchant}`,
    );
  }

  if (!apply) {
    console.log('\nre-run with --apply to write');
    await prisma.$disconnect();
    return;
  }

  let written = 0;
  for (const c of changes) {
    await prisma.transaction.update({
      where: { id: c.id },
      data: { vpaGateway: c.toGateway, vpaMerchant: c.toMerchant },
    });
    written++;
  }
  console.log(`\nwrote ${written} rows`);

  const byGateway = await prisma.transaction.groupBy({
    by: ['vpaGateway'],
    where: { vpaGateway: { not: null } },
    _count: true,
  });
  console.log('\ngateway distribution:');
  for (const g of byGateway.sort((a, b) => b._count - a._count)) {
    console.log(`  ${String(g.vpaGateway).padEnd(12)} ${g._count}`);
  }

  await prisma.$disconnect();
}

main().catch(async (err) => {
  console.error(err);
  await prisma.$disconnect();
  process.exit(1);
});
