// One-shot cleanup for transactions that landed in the DB before the
// new strict pipeline shipped. Three passes, all safe to re-run:
//
//   PASS 1 — reset bad Places resolutions on online merchants
//     The old recategorize step would happily tag NAME-CHEAP.COM as
//     "Groceries / Vishal Mega Mart" because it asked iPhone for GPS at
//     the time the domain renewal landed. Undo those.
//
//   PASS 2 — re-apply alias matching with the expanded seed list
//     We added ~70 new merchant aliases (Namecheap, Anthropic, GCP,
//     streaming services, etc). Existing rows still have the old
//     categorization (or none). Re-run alias lookup on every row that
//     isn't already alias-resolved and apply the new category.
//
//   PASS 3 — re-run Places match on rows that have saved coordinates
//     iOS uploaded GPS for these rows earlier, but they were either
//     resolved by the old loose logic or skipped entirely. Re-run with
//     the new strict 10m radius + 15m haversine + single-strong-match
//     rule. Some will re-resolve cleanly; ambiguous ones drop to review.
//     Costs ~1 Places API call per row (basic SKU).
//
// Usage:  npx tsx scripts/cleanup-stale-data.ts [--dry-run] [--skip-places]
//
// --dry-run    : log changes that WOULD be made, don't touch the DB
// --skip-places: skip PASS 3 (no Places API calls; useful if quota is tight)

import { prisma } from '../src/db/client.js';
import {
  lookupAlias,
  stripRoutingPrefix,
} from '../src/categorize/aliases.js';
import { detectOnlineMerchant } from '../src/categorize/onlineMerchant.js';
import { recategorizeWithLocation } from '../src/pipeline/recategorizeWithLocation.js';
import { ROUTING_PREFIXES } from '../src/categorize/seed.js';
import { listMerchantAliases } from '../src/db/aliases.js';

const args = new Set(process.argv.slice(2));
const DRY_RUN = args.has('--dry-run');
const SKIP_PLACES = args.has('--skip-places');

interface Stats {
  pass1OnlineCleaned: number;
  pass2AliasReapplied: number;
  pass3PlacesUpdated: number;
  pass3PlacesAmbiguous: number;
  pass3PlacesNoMatch: number;
  pass3PlacesSkipped: number;
}

async function main() {
  const stats: Stats = {
    pass1OnlineCleaned: 0,
    pass2AliasReapplied: 0,
    pass3PlacesUpdated: 0,
    pass3PlacesAmbiguous: 0,
    pass3PlacesNoMatch: 0,
    pass3PlacesSkipped: 0,
  };

  if (DRY_RUN) {
    console.log('🟡 DRY RUN — no DB writes will be made\n');
  }

  // Pull live aliases from the DB. The script ASSUMES `npm run db:seed`
  // has been run after the seed list was expanded, so the DB has the
  // new entries (Namecheap, Anthropic, GCP, etc).
  const aliases = await listMerchantAliases();
  console.log(`Loaded ${aliases.length} aliases from DB\n`);

  // === PASS 1 — reset bad Places tags on online merchants ===
  console.log('=== PASS 1 — reset stale Places tags on online merchants ===');

  const placesRows = await prisma.transaction.findMany({
    where: { signalSource: 'places' },
    select: {
      id: true,
      merchantRaw: true,
      merchantNormalized: true,
      categoryId: true,
      locationLat: true,
      locationLng: true,
    },
  });

  for (const tx of placesRows) {
    const check = detectOnlineMerchant(tx.merchantRaw);
    if (!check.isOnline) continue;

    console.log(
      `  reset ${tx.id} — "${tx.merchantRaw}" (online: ${check.reason}/${check.matched}) ` +
        `was tagged "${tx.merchantNormalized}"`,
    );
    if (!DRY_RUN) {
      await prisma.transaction.update({
        where: { id: tx.id },
        data: {
          merchantNormalized: tx.merchantRaw,
          categoryId: null,
          status: 'pending_review',
          confidence: null,
          signalSource: null,
          locationLat: null,
          locationLng: null,
          locationStatus: 'not_applicable',
        },
      });
    }
    stats.pass1OnlineCleaned++;
  }
  console.log(`  → ${stats.pass1OnlineCleaned} rows reset\n`);

  // === PASS 2 — re-apply alias matching ===
  console.log('=== PASS 2 — re-apply alias matching with expanded seeds ===');

  // Pick up everything that COULD benefit: pending_review rows AND rows
  // that have no category yet AND rows still tagged 'places' (those that
  // pass 1 didn't reset because they're physical merchants — we may
  // still find an alias hit, in which case alias wins over Places).
  const candidates = await prisma.transaction.findMany({
    where: {
      OR: [
        { categoryId: null },
        { status: 'pending_review' },
        { signalSource: 'places' },
      ],
      direction: 'out',
    },
    select: {
      id: true,
      merchantRaw: true,
      signalSource: true,
    },
  });

  for (const tx of candidates) {
    const normalized = stripRoutingPrefix(tx.merchantRaw, ROUTING_PREFIXES);
    const hit = lookupAlias(normalized, aliases);
    if (!hit || !hit.category) continue;

    // Don't downgrade a more-specific signal. If this row is already
    // alias-resolved (signal=alias), nothing to do.
    if (tx.signalSource === 'alias') continue;

    const cat = await prisma.category.findUnique({
      where: { name: hit.category },
    });
    if (!cat) continue;

    console.log(
      `  re-tag ${tx.id} — "${tx.merchantRaw}" → ${hit.canonical} (${hit.category})`,
    );
    if (!DRY_RUN) {
      await prisma.transaction.update({
        where: { id: tx.id },
        data: {
          merchantNormalized: hit.canonical,
          categoryId: cat.id,
          status: 'resolved',
          confidence: 0.95,
          signalSource: 'alias',
          // If we were on Places, the coords pointed at a misidentified
          // physical shop. Clear them — alias hits are online charges.
          ...(tx.signalSource === 'places'
            ? {
                locationLat: null,
                locationLng: null,
                locationStatus: 'not_applicable',
              }
            : {}),
        },
      });
    }
    stats.pass2AliasReapplied++;
  }
  console.log(`  → ${stats.pass2AliasReapplied} rows re-tagged via alias\n`);

  // === PASS 3 — re-run Places on rows with existing coordinates ===
  if (SKIP_PLACES) {
    console.log('=== PASS 3 — SKIPPED (--skip-places) ===\n');
  } else {
    console.log('=== PASS 3 — re-run strict Places match on rows with coords ===');

    const withCoords = await prisma.transaction.findMany({
      where: {
        locationLat: { not: null },
        locationLng: { not: null },
        direction: 'out',
        // Skip rows that an alias just claimed in pass 2 — we cleared
        // their coords there anyway, but be defensive.
        NOT: { signalSource: 'alias' },
      },
      select: {
        id: true,
        merchantRaw: true,
        locationLat: true,
        locationLng: true,
        signalSource: true,
      },
    });

    for (const tx of withCoords) {
      // Skip online merchants — they shouldn't have coords at all but
      // some legacy rows might.
      if (detectOnlineMerchant(tx.merchantRaw).isOnline) {
        stats.pass3PlacesSkipped++;
        continue;
      }
      if (tx.locationLat === null || tx.locationLng === null) continue;

      if (DRY_RUN) {
        console.log(
          `  would re-run Places for ${tx.id} — "${tx.merchantRaw}" @ ${tx.locationLat},${tx.locationLng}`,
        );
        continue;
      }

      const outcome = await recategorizeWithLocation({
        transactionId: tx.id,
        lat: Number(tx.locationLat),
        lng: Number(tx.locationLng),
      });

      if (outcome.updated) {
        stats.pass3PlacesUpdated++;
        console.log(
          `  ✓ ${tx.id} — "${tx.merchantRaw}" → ${outcome.newMerchant} (${outcome.newCategory})`,
        );
      } else if (outcome.reason.startsWith('ambiguous')) {
        stats.pass3PlacesAmbiguous++;
        console.log(`  ⚠ ${tx.id} ambiguous (${outcome.reason}) — left for review`);
      } else {
        stats.pass3PlacesNoMatch++;
        console.log(`  · ${tx.id} no match (${outcome.reason})`);
      }
    }
    console.log(
      `  → updated:${stats.pass3PlacesUpdated} ambiguous:${stats.pass3PlacesAmbiguous} ` +
        `no_match:${stats.pass3PlacesNoMatch} skipped_online:${stats.pass3PlacesSkipped}\n`,
    );
  }

  console.log('=== Summary ===');
  console.log(`  online cleanups : ${stats.pass1OnlineCleaned}`);
  console.log(`  alias re-tags   : ${stats.pass2AliasReapplied}`);
  console.log(`  places updates  : ${stats.pass3PlacesUpdated}`);
  console.log(`  places ambig.   : ${stats.pass3PlacesAmbiguous}`);
  console.log(`  places no match : ${stats.pass3PlacesNoMatch}`);
  if (DRY_RUN) console.log('\n(DRY RUN — no writes were made)');
}

main()
  .catch((err) => {
    console.error(err);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
