// One-shot data snapshot for triage. Prints every transaction in the DB
// with all the fields that matter for debugging categorization +
// receipts + Places + budgets, plus aggregate breakdowns.
//
// Usage: DATABASE_URL=... npx tsx scripts/data-snapshot.ts

import { prisma } from '../src/db/client.js';

async function main() {
  // --- Aggregates --------------------------------------------------------

  const total = await prisma.transaction.count();
  const byStatus = await prisma.transaction.groupBy({
    by: ['status'],
    _count: { _all: true },
  });
  const bySignal = await prisma.transaction.groupBy({
    by: ['signalSource'],
    _count: { _all: true },
  });
  const byInstrument = await prisma.transaction.groupBy({
    by: ['instrument'],
    _count: { _all: true },
  });
  const byLocation = await prisma.transaction.groupBy({
    by: ['locationStatus'],
    _count: { _all: true },
  });
  const byCategory = await prisma.transaction.findMany({
    select: { category: { select: { name: true } } },
  });
  const catCounts: Record<string, number> = {};
  for (const r of byCategory) {
    const k = r.category?.name ?? '(null)';
    catCounts[k] = (catCounts[k] ?? 0) + 1;
  }

  console.log('═'.repeat(72));
  console.log('TRANSACTION AGGREGATES');
  console.log('═'.repeat(72));
  console.log(`Total transactions: ${total}\n`);

  console.log('By status:');
  for (const r of byStatus) console.log(`  ${pad(r.status, 22)} ${r._count._all}`);
  console.log('\nBy signal source:');
  for (const r of bySignal) console.log(`  ${pad(r.signalSource ?? '(null)', 22)} ${r._count._all}`);
  console.log('\nBy instrument:');
  for (const r of byInstrument) console.log(`  ${pad(r.instrument, 22)} ${r._count._all}`);
  console.log('\nBy location status:');
  for (const r of byLocation) console.log(`  ${pad(r.locationStatus, 22)} ${r._count._all}`);
  console.log('\nBy category:');
  for (const [k, v] of Object.entries(catCounts).sort((a, b) => b[1] - a[1])) {
    console.log(`  ${pad(k, 36)} ${v}`);
  }

  // --- Transactions ------------------------------------------------------

  const rows = await prisma.transaction.findMany({
    orderBy: { occurredAt: 'desc' },
    include: {
      category: { select: { name: true } },
      receipts: { take: 1, orderBy: { receivedAt: 'desc' } },
    },
  });

  console.log('\n' + '═'.repeat(72));
  console.log('TRANSACTIONS (newest first)');
  console.log('═'.repeat(72));
  console.log(
    `${pad('DATE', 11)} ${pad('AMT', 10)} ${pad('INSTR', 14)} ${pad('CATEGORY', 26)} ${pad('SIG', 9)} ${pad('LOC', 7)} R MERCHANT / VPA`,
  );
  console.log('─'.repeat(72));
  for (const r of rows) {
    const date = r.occurredAt.toISOString().slice(0, 10);
    const amt = r.amountInrMinor !== null ? '₹' + (Number(r.amountInrMinor) / 100).toFixed(0) : '?';
    const cat = r.category?.name ?? '—';
    const sig = r.signalSource ?? '—';
    const loc = r.locationLat !== null ? '✓' : (r.locationStatus.slice(0, 6));
    const receipt = r.receipts[0] ? r.receipts[0].source.slice(0, 1).toUpperCase() : '·';
    const merchant = r.merchantRaw.slice(0, 30);
    const vpa = r.vpa ? ` (${r.vpa})` : '';
    console.log(
      `${pad(date, 11)} ${pad(amt, 10)} ${pad(r.instrument, 14)} ${pad(cat, 26)} ${pad(sig, 9)} ${pad(loc, 7)} ${receipt} ${merchant}${vpa}`,
    );
  }

  // --- Budgets -----------------------------------------------------------

  const budgets = await prisma.budget.findMany({
    include: { category: { select: { name: true } } },
  });
  console.log('\n' + '═'.repeat(72));
  console.log('BUDGETS');
  console.log('═'.repeat(72));
  for (const b of budgets) {
    const limit = Number(b.monthlyLimitInr) / 100;
    console.log(`  ${pad(b.category.name, 32)} ₹${limit.toFixed(0)} (${b.enabled ? 'on' : 'off'})`);
  }

  // --- Receipts ----------------------------------------------------------

  const receipts = await prisma.emailReceipt.findMany({
    orderBy: { receivedAt: 'desc' },
  });
  const receiptsByCohort: Record<string, { total: number; bound: number; withItems: number }> = {};
  for (const r of receipts) {
    const k = r.source;
    receiptsByCohort[k] ??= { total: 0, bound: 0, withItems: 0 };
    receiptsByCohort[k]!.total++;
    if (r.transactionId) receiptsByCohort[k]!.bound++;
    if (r.itemsJson) receiptsByCohort[k]!.withItems++;
  }
  console.log('\n' + '═'.repeat(72));
  console.log(`RECEIPTS (${receipts.length} total)`);
  console.log('═'.repeat(72));
  console.log(`${pad('SOURCE', 16)} TOTAL  BOUND  WITH-ITEMS`);
  for (const [k, v] of Object.entries(receiptsByCohort).sort((a, b) => b[1].total - a[1].total)) {
    console.log(`${pad(k, 16)} ${pad(String(v.total), 6)} ${pad(String(v.bound), 6)} ${v.withItems}`);
  }

  // --- Merchant patterns ------------------------------------------------

  const patterns = await prisma.merchantPattern.findMany({
    orderBy: { hitCount: 'desc' },
    include: { category: { select: { name: true } } },
  });
  console.log('\n' + '═'.repeat(72));
  console.log(`LEARNED MERCHANT PATTERNS (${patterns.length} total)`);
  console.log('═'.repeat(72));
  console.log(`${pad('MERCHANT', 36)} ${pad('CATEGORY', 28)} HITS  AUTO`);
  for (const p of patterns.slice(0, 30)) {
    const auto = p.autoTagActive ? '✓' : '·';
    console.log(`${pad(p.merchantNormalized.slice(0, 35), 36)} ${pad(p.category.name, 28)} ${pad(String(p.hitCount), 5)} ${auto}`);
  }
}

function pad(s: string, n: number): string {
  return s.length >= n ? s.slice(0, n) : s + ' '.repeat(n - s.length);
}

main()
  .catch((err) => { console.error(err); process.exit(1); })
  .finally(async () => { await prisma.$disconnect(); });
