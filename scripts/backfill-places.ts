// One-shot: re-run recategorizeWithLocation against every historical
// transaction that already has GPS coordinates saved. Now that the
// recategorize pass persists `placesSuggestions` (top-N nearby
// candidates) regardless of whether it can auto-tag, this backfill
// surfaces the "Nearby places" picker on existing rows.
//
// Cost: ~$0.05 per row via Places Basic SKU. Safe to re-run (idempotent
// on transaction id — the recategorize update is replace-style).
//
// Usage:
//   DATABASE_URL=... GOOGLE_PLACES_API_KEY=... \
//     npx tsx scripts/backfill-places.ts [--limit N]

import { prisma } from '../src/db/client.js';
import { recategorizeWithLocation } from '../src/pipeline/recategorizeWithLocation.js';

async function main() {
  const limitArg = process.argv.find((a) => a.startsWith('--limit='));
  const limit = limitArg ? Number(limitArg.split('=')[1]) : 200;

  // Only rows that:
  //   - have actual lat/lng saved (else there's nothing to query Places against)
  //   - are outflows (location is meaningless for inflows)
  //   - haven't already had a Places match auto-applied (preserves
  //     existing resolutions; the recategorize will overwrite if a new
  //     single-strong match is found, but otherwise leaves the data)
  const rows = await prisma.transaction.findMany({
    where: {
      direction: 'out',
      locationLat: { not: null },
      locationLng: { not: null },
    },
    select: { id: true, locationLat: true, locationLng: true, merchantRaw: true },
    orderBy: { occurredAt: 'desc' },
    take: limit,
  });

  console.log(`Found ${rows.length} rows with coords. Backfilling...\n`);

  let updated = 0;
  let suggestionsAdded = 0;
  let noMatch = 0;
  let errors = 0;

  for (const row of rows) {
    if (row.locationLat === null || row.locationLng === null) continue;
    try {
      // Read placesSuggestions before, so we can detect whether the
      // backfill freshly populated it.
      const before = await prisma.transaction.findUnique({
        where: { id: row.id },
        select: { placesSuggestions: true, signalSource: true },
      });
      const hadSuggestionsBefore = before?.placesSuggestions !== null;

      const outcome = await recategorizeWithLocation({
        transactionId: row.id,
        lat: Number(row.locationLat),
        lng: Number(row.locationLng),
      });

      const after = await prisma.transaction.findUnique({
        where: { id: row.id },
        select: { placesSuggestions: true, signalSource: true },
      });
      const hasSuggestionsAfter = after?.placesSuggestions !== null;

      if (outcome.updated) {
        updated++;
        console.log(`  ✓ ${row.id} — ${row.merchantRaw.slice(0, 30)} → ${outcome.newMerchant} (${outcome.newCategory})`);
      } else if (!hadSuggestionsBefore && hasSuggestionsAfter) {
        suggestionsAdded++;
        console.log(`  + ${row.id} — ${row.merchantRaw.slice(0, 30)} (${outcome.reason}) — suggestions saved`);
      } else {
        noMatch++;
      }
    } catch (err) {
      errors++;
      console.error(`  ✗ ${row.id}: ${(err as Error).message.slice(0, 100)}`);
    }
  }

  console.log('\n' + '═'.repeat(60));
  console.log('BACKFILL SUMMARY');
  console.log('═'.repeat(60));
  console.log(`Rows scanned:        ${rows.length}`);
  console.log(`Auto-tagged:         ${updated}`);
  console.log(`Suggestions added:   ${suggestionsAdded}`);
  console.log(`No nearby match:     ${noMatch}`);
  console.log(`Errors:              ${errors}`);
}

main()
  .catch((err) => { console.error(err); process.exit(1); })
  .finally(async () => { await prisma.$disconnect(); });
