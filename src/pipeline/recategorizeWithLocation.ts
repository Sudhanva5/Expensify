// Re-categorize a transaction once iOS has uploaded its location.
//
// Flow:
//   1. Pull the latest row from DB (skip if already alias-resolved or not an outflow)
//   2. Query Google Places API for businesses within 100m
//   3. Walk the candidates; pick the first one whose `types` map to one of
//      our V1 categories via the static mapper. The Places display name is
//      authoritative ("MTR Hotel" not "RAJESH KUMAR"); the matched category
//      becomes the new transaction category.
//   4. If a match is found, update the row:
//        - merchantNormalized = Places display name
//        - categoryId = matched category
//        - status = resolved (drops out of review queue)
//        - locationLat / locationLng = Places candidate's coordinates (so the
//          "open in Maps" tap lands on the actual storefront, not the user's
//          approximate phone GPS)
//   5. Otherwise leave row pending_review for the user to swipe
//
// Called fire-and-forget from POST /transactions/:id/location so the location
// upload returns 200 immediately — re-categorize runs in the background.
//
// Places' `types[]` is already a structured signal — Italian restaurant,
// gas station, transit station, etc. A static type→category map is faster,
// cheaper, and deterministic. No LLM call needed.

import { prisma } from '../db/client.js';
import { Prisma } from '@prisma/client';
import { buildOptionalPlacesClient } from '../services/places.js';
import {
  mapPlacesTypesToCategory,
  PLACES_TYPE_CONFIDENCE,
} from '../services/placesTypeMapper.js';
import { checkBudgetForCategory } from './budgetAlerts.js';

export type RecategorizeOutcome =
  | {
      updated: true;
      newCategory: string;
      newMerchant: string | null;
      confidence: number;
      matchedPlacesType: string;
    }
  | { updated: false; reason: string };

export async function recategorizeWithLocation(opts: {
  transactionId: string;
  lat: number;
  lng: number;
}): Promise<RecategorizeOutcome> {
  const places = buildOptionalPlacesClient();
  if (!places) return { updated: false, reason: 'places_not_configured' };

  const tx = await prisma.transaction.findUnique({
    where: { id: opts.transactionId },
    include: { category: { select: { name: true } } },
  });
  if (!tx) return { updated: false, reason: 'transaction_not_found' };

  // Already-confident rows don't need re-tagging. Inflows / autopays don't
  // have a meaningful "where did this happen" anyway.
  if (tx.status === 'resolved' && tx.signalSource === 'alias') {
    return { updated: false, reason: 'already_alias_resolved' };
  }
  if (tx.direction !== 'out') {
    return { updated: false, reason: 'not_outflow' };
  }

  // Look up nearby places. 10m is intentionally tight — wider radii were
  // returning confidently-wrong matches for shops next door. iPhone GPS is
  // typically accurate to ~5-10m outdoors; tightening to that keeps us
  // honest. The trade-off is more "no_nearby_places" outcomes, which is
  // fine — those drop into the review queue and the user resolves them.
  let candidates;
  try {
    candidates = await places.nearby({ lat: opts.lat, lng: opts.lng, radiusMeters: 10 });
  } catch (err) {
    console.error('[recategorize] Places lookup failed:', err);
    return { updated: false, reason: 'places_call_failed' };
  }
  if (candidates.length === 0) {
    return { updated: false, reason: 'no_nearby_places' };
  }

  // The Places API "radius" is a hint, not a hard filter — it'll happily
  // return shops 20-30m away when ranked by relevance. Re-filter strictly
  // using a real haversine distance on the candidate centroids, so we only
  // consider places that are physically within ~15m of the transaction GPS.
  // (Slightly wider than the request radius to absorb GPS jitter on both
  // ends of the comparison.)
  const STRICT_DISTANCE_M = 15;
  const tightlyNearby = candidates.filter((c) => {
    if (!c.lat || !c.lng) return false;
    return haversineMeters(opts.lat, opts.lng, c.lat, c.lng) <= STRICT_DISTANCE_M;
  });
  if (tightlyNearby.length === 0) {
    return { updated: false, reason: 'no_places_within_strict_distance' };
  }

  // Find every candidate whose types map to a V1 category.
  const matched = tightlyNearby
    .map((c) => ({ candidate: c, match: mapPlacesTypesToCategory(c.types) }))
    .filter((row): row is { candidate: typeof tightlyNearby[number]; match: NonNullable<ReturnType<typeof mapPlacesTypesToCategory>> } => row.match !== null);

  // Persist the top mapped candidates as "suggestions" regardless of
  // whether we can auto-pick one. iOS surfaces these as a "Nearby
  // places" picker in the detail sheet so the user can claim the right
  // one in one tap. Saved with distance + category so the picker can
  // show meaningful chips.
  const suggestions = matched.slice(0, 5).map(({ candidate, match }) => ({
    name: candidate.name,
    category: match.category,
    distanceM: Math.round(
      haversineMeters(opts.lat, opts.lng, candidate.lat || opts.lat, candidate.lng || opts.lng),
    ),
    lat: candidate.lat,
    lng: candidate.lng,
    formattedAddress: candidate.formattedAddress ?? null,
  }));
  if (suggestions.length > 0) {
    await prisma.transaction.update({
      where: { id: tx.id },
      data: {
        placesSuggestions: suggestions as unknown as Prisma.InputJsonValue,
      },
    });
  }

  if (matched.length === 0) {
    return { updated: false, reason: 'no_recognized_place_type' };
  }
  if (matched.length > 1) {
    // Multiple mapped candidates — can't pick ONE confidently, but the
    // user gets to see all of them via the persisted suggestions above.
    return {
      updated: false,
      reason: `ambiguous_${matched.length}_candidates`,
    };
  }

  const chosen = matched[0]!.candidate;
  const match = matched[0]!.match;

  const catRow = await prisma.category.findUnique({
    where: { name: match.category },
  });
  if (!catRow) {
    return { updated: false, reason: `unknown_category_${match.category}` };
  }

  // Fire-and-forget budget check after the category update lands (the
  // assigned category might be different from what initial categorization
  // picked, so we re-check budgets on the new one).
  void checkBudgetForCategory(catRow.id).catch((err) =>
    console.error('[budgetAlerts] check failed after recategorize:', err),
  );

  await prisma.transaction.update({
    where: { id: tx.id },
    data: {
      merchantNormalized: chosen.name,
      categoryId: catRow.id,
      status: 'resolved',
      confidence: match.confidence,
      signalSource: 'places',
      // Snap location to the Places centroid so the "open in Maps" tap
      // lands on the storefront, not the phone's GPS.
      locationLat: chosen.lat || tx.locationLat,
      locationLng: chosen.lng || tx.locationLng,
      updatedAt: new Date(),
    },
  });

  console.log(
    `[recategorize] resolved ${tx.id}: ${chosen.name} → ${match.category} (via type "${match.matchedType}", conf ${match.confidence})`,
  );

  return {
    updated: true,
    newCategory: match.category,
    newMerchant: chosen.name,
    confidence: match.confidence,
    matchedPlacesType: match.matchedType,
  };
}

/**
 * Great-circle distance between two lat/lng points, in metres.
 * Standard haversine formula — accurate enough at the metre scale that
 * matters for our "is this candidate physically inside the radius" check.
 */
function haversineMeters(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number,
): number {
  const R = 6_371_000; // Earth radius in metres
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}
