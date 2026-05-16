// Re-run the Places lookup for every transaction whose VPA matches a
// given filter, and persist the top-5 nearby candidates as the row's
// `placesSuggestions` (without auto-resolving).
//
//   npx tsx scripts/refresh-places-by-vpa.ts --vpa "<exact-or-substring>"
//   npx tsx scripts/refresh-places-by-vpa.ts --merchant "SURENDRA SHETTY"
//   npx tsx scripts/refresh-places-by-vpa.ts --all
//
// Idempotent — overwrites placesSuggestions on each matching row. Does
// NOT touch categoryId / status / signalSource, so user-tagged rows
// keep their tag; the picker just gets more options to choose from.

import { prisma } from '../src/db/client.js';
import { Prisma } from '@prisma/client';
import { buildOptionalPlacesClient } from '../src/services/places.js';
import { mapPlacesTypesToCategory } from '../src/services/placesTypeMapper.js';

function getArg(name: string): string | null {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx < 0) return null;
  return process.argv[idx + 1] ?? null;
}

const STRICT_DISTANCE_M = 30;

async function main() {
  const vpaFilter = getArg('vpa');
  const merchantFilter = getArg('merchant');
  const allFlag = process.argv.includes('--all');
  if (!vpaFilter && !merchantFilter && !allFlag) {
    console.error('Usage: refresh-places-by-vpa.ts --vpa <substr> | --merchant <substr> | --all');
    process.exit(2);
  }

  const places = buildOptionalPlacesClient();
  if (!places) {
    console.error('GOOGLE_PLACES_API_KEY not configured in env');
    process.exit(2);
  }

  const txs = await prisma.transaction.findMany({
    where: {
      direction: 'out',
      locationLat: { not: null },
      locationLng: { not: null },
      ...(vpaFilter ? { vpa: { contains: vpaFilter, mode: 'insensitive' } } : {}),
      ...(merchantFilter
        ? {
            OR: [
              { merchantRaw: { contains: merchantFilter, mode: 'insensitive' } },
              { merchantNormalized: { contains: merchantFilter, mode: 'insensitive' } },
            ],
          }
        : {}),
    },
    select: {
      id: true,
      merchantRaw: true,
      vpa: true,
      locationLat: true,
      locationLng: true,
    },
  });
  console.log(`[refresh-places] scanning ${txs.length} matching transaction(s)`);

  let updated = 0;
  let empty = 0;
  for (const tx of txs) {
    if (!tx.locationLat || !tx.locationLng) continue;
    const lat = Number(tx.locationLat);
    const lng = Number(tx.locationLng);

    let candidates;
    try {
      candidates = await places.nearby({ lat, lng, radiusMeters: STRICT_DISTANCE_M });
    } catch (err) {
      console.warn(`  ${tx.id}: places call failed — ${(err as Error).message}`);
      continue;
    }
    if (candidates.length === 0) {
      empty++;
      continue;
    }

    const tightly = candidates.filter((c) => {
      if (!c.lat || !c.lng) return false;
      return haversineMeters(lat, lng, c.lat, c.lng) <= STRICT_DISTANCE_M;
    });
    const matched = tightly
      .map((c) => ({ candidate: c, match: mapPlacesTypesToCategory(c.types) }))
      .filter(
        (row): row is { candidate: typeof tightly[number]; match: NonNullable<ReturnType<typeof mapPlacesTypesToCategory>> } =>
          row.match !== null,
      );

    const suggestions = matched.slice(0, 5).map(({ candidate, match }) => ({
      name: candidate.name,
      category: match.category,
      distanceM: Math.round(
        haversineMeters(lat, lng, candidate.lat || lat, candidate.lng || lng),
      ),
      lat: candidate.lat,
      lng: candidate.lng,
      formattedAddress: candidate.formattedAddress ?? null,
    }));

    await prisma.transaction.update({
      where: { id: tx.id },
      data: {
        placesSuggestions: suggestions as unknown as Prisma.InputJsonValue,
      },
    });
    updated++;
    console.log(
      `  ${tx.id} (${tx.merchantRaw.slice(0, 30)}): ${suggestions.length} nearby place(s) saved`,
    );
  }

  console.log(`[refresh-places] updated=${updated} empty=${empty}`);
}

function haversineMeters(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6_371_000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error('[refresh-places] failed:', err);
    process.exit(1);
  });
