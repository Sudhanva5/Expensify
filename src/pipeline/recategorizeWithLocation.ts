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
// Why no Groq here?  Places' `types[]` is already a structured signal — Italian
// restaurant, gas station, transit station, etc. A static type→category map is
// faster, cheaper (zero LLM calls), and deterministic. Groq remains the
// fallback inside the main categorization tier chain; this path only fires
// when we have a location and want to enrich an already-ingested row.

import { prisma } from '../db/client.js';
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

  // Look up nearby places
  let candidates;
  try {
    candidates = await places.nearby({ lat: opts.lat, lng: opts.lng, radiusMeters: 100 });
  } catch (err) {
    console.error('[recategorize] Places lookup failed:', err);
    return { updated: false, reason: 'places_call_failed' };
  }
  if (candidates.length === 0) {
    return { updated: false, reason: 'no_nearby_places' };
  }

  // Walk candidates in the order Places returned them; the first one whose
  // types map to a V1 category wins. Places typically orders by relevance
  // / proximity, so the first hit is usually the right one. Skipping over
  // unrecognized types lets the chosen merchant be a real storefront
  // instead of, say, a "neighborhood" or "premise" polygon.
  let chosen: typeof candidates[number] | undefined;
  let match: ReturnType<typeof mapPlacesTypesToCategory> = null;
  for (const candidate of candidates) {
    const m = mapPlacesTypesToCategory(candidate.types);
    if (m) {
      chosen = candidate;
      match = m;
      break;
    }
  }
  if (!chosen || !match) {
    return { updated: false, reason: 'no_recognized_place_type' };
  }

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
      // Reuse existing enum slot — Places+typeMapper plays the same role
      // as the previous Places+Groq path used to.
      signalSource: 'brave_groq',
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
