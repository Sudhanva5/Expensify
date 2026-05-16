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
import { detectOnlineMerchant } from '../categorize/onlineMerchant.js';
import { evaluateRule } from '../categorize/rules.js';
import { classifyVpa } from '../categorize/vpaShape.js';
import { listEnabledRules } from '../db/userRules.js';
import { checkBudgetForCategory } from './budgetAlerts.js';
import { AUTO_TAG_CONFIDENCE_THRESHOLD } from '../categorize/types.js';
import type { ParsedTransaction } from '../parsers/hdfc/index.js';

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

  // Already-confident rows don't need re-tagging. Skip any resolved row
  // whose signal source we trust at auto-tag confidence — alias,
  // autopay alias, an explicit merchant or VPA pattern hit, a user rule,
  // or a previously-claimed Places suggestion. Without this, a backfill
  // sweep or a manual GPS re-upload could overwrite a confirmation the
  // user has already made.
  const TRUSTED_SOURCES = new Set([
    'alias',
    'autopay_alias',
    'merchant_pattern',
    'user_rule',
    'places',
  ]);
  if (tx.status === 'resolved' && tx.signalSource && TRUSTED_SOURCES.has(tx.signalSource)) {
    return { updated: false, reason: `already_resolved_${tx.signalSource}` };
  }
  if (tx.direction !== 'out') {
    return { updated: false, reason: 'not_outflow' };
  }
  // Online-merchant guard — DUPLICATED here on purpose. The check in
  // processGmailMessage prevents NEW online-merchant rows from being
  // sent through this pipeline at all, but historical rows already
  // have GPS uploaded. If a backfill or manual re-run calls
  // recategorizeWithLocation on a "NAME-CHEAP.COM*" row, we'd happily
  // map it to the nearest physical grocery store — exactly the bug
  // we fixed before. Belt-and-suspenders: bail out here too.
  const onlineCheck = detectOnlineMerchant(tx.merchantRaw);
  if (onlineCheck.isOnline) {
    return {
      updated: false,
      reason: `online_merchant_${onlineCheck.reason}`,
    };
  }

  // P2P guard — the GPay-rail equivalent of the online-merchant guard.
  // Personal-shape VPAs (sneha.r@oksbi, sagarprabhu251-1@okhdfcbank,
  // 9876543210@ybl) are person-to-person UPI transfers, not visits to
  // a physical storefront. Without this, a ₹1 test payment to a friend
  // would happily snap to the nearest ice-cream shop and rename the
  // row "Apsara Ice Creams" — exactly the bug we just hit. Refuse to
  // Places-resolve any personal VPA, full stop.
  if (tx.vpa && classifyVpa(tx.vpa) === 'personal') {
    return { updated: false, reason: 'p2p_vpa' };
  }

  // Re-evaluate user rules with location context. Rules can carry a
  // `locationWithinRadius` condition (e.g. "near my office") that's
  // impossible to evaluate at ingest. Now that we have the iPhone's
  // GPS, walk through rules priority-first and apply any that fire
  // at auto-tag confidence (≥0.95). User rules beat Places matching
  // because user intent is more reliable than nearby-shop guesses.
  const ruleHit = await tryApplyLocationAwareRule({
    tx,
    lat: opts.lat,
    lng: opts.lng,
  });
  if (ruleHit) return ruleHit;

  // Ask Places for a 30m sample so the haversine filter at STRICT_DISTANCE_M
  // has enough candidates to choose from. Auto-tag still requires single-
  // strong-match within the strict radius; widening the search just gives
  // the suggestion picker more rows to render.
  let candidates;
  try {
    candidates = await places.nearby({ lat: opts.lat, lng: opts.lng, radiusMeters: 30 });
  } catch (err) {
    console.error('[recategorize] Places lookup failed:', err);
    return { updated: false, reason: 'places_call_failed' };
  }
  if (candidates.length === 0) {
    return { updated: false, reason: 'no_nearby_places' };
  }

  // The Places API "radius" is a hint, not a hard filter — it'll happily
  // return shops further away when ranked by relevance. Re-filter strictly
  // using a real haversine distance on the candidate centroids, so we only
  // consider places that are physically within ~30m of the transaction GPS.
  // 30m absorbs typical urban GPS jitter (5-25m on iPhone) without pulling
  // in the next plaza.
  const STRICT_DISTANCE_M = 30;
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
 * Walk enabled user rules that carry a `locationWithinRadius` condition,
 * pick the highest-priority match, and apply it. Only rules with confidence
 * ≥ AUTO_TAG_CONFIDENCE_THRESHOLD auto-tag here — anything lower is left
 * for the Places pass / review queue to handle.
 *
 * Pattern: the "near my office → Travel" rule. User stands in front of the
 * office, pays a Rapido rider ₹250 to a random personal VPA. No alias
 * matches, no merchant fingerprint exists yet — but the geo+amount+time
 * shape says "cab fare" with high confidence.
 */
async function tryApplyLocationAwareRule(opts: {
  tx: {
    id: string;
    direction: 'in' | 'out';
    instrument: string;
    amountMinor: bigint;
    currency: string;
    amountInrMinor: bigint | null;
    merchantRaw: string;
    vpa: string | null;
    occurredAt: Date;
    signalSource: string | null;
    locationLat: Prisma.Decimal | null;
    locationLng: Prisma.Decimal | null;
  };
  lat: number;
  lng: number;
}): Promise<RecategorizeOutcome | null> {
  const rules = await listEnabledRules();
  const locationRules = rules.filter(
    (r) => r.conditions.locationWithinRadius !== undefined,
  );
  if (locationRules.length === 0) return null;

  // evaluateRule expects a ParsedTransaction; the DB row carries the same
  // fields plus a few extras. Build a minimal compatible object — the
  // evaluator only reads direction/instrument/amount/time/merchant/vpa.
  const parsedLike: ParsedTransaction = {
    template: 'upi_debit',
    direction: opts.tx.direction,
    instrument: opts.tx.instrument,
    amountMinor: opts.tx.amountMinor,
    currency: opts.tx.currency,
    amountInrMinor: opts.tx.amountInrMinor,
    bankConvertedRate: null,
    merchantRaw: opts.tx.merchantRaw,
    vpa: opts.tx.vpa,
    occurredAt: opts.tx.occurredAt,
    externalRef: null,
    isAutopay: false,
  };

  const ctx = {
    aliasMatched: opts.tx.signalSource === 'alias',
    vpaShape: opts.tx.vpa ? classifyVpa(opts.tx.vpa) : ('unknown' as const),
    txLat: opts.lat,
    txLng: opts.lng,
  };

  // listEnabledRules already returns rows sorted by priority desc; take the
  // first matching rule that fires at auto-tag confidence.
  for (const rule of locationRules) {
    if (!evaluateRule(rule, parsedLike, ctx)) continue;
    if (rule.confidence < AUTO_TAG_CONFIDENCE_THRESHOLD) continue;

    const catRow = await prisma.category.findUnique({
      where: { name: rule.suggestCategory },
    });
    if (!catRow) continue;

    await prisma.transaction.update({
      where: { id: opts.tx.id },
      data: {
        categoryId: catRow.id,
        status: 'resolved',
        confidence: rule.confidence,
        signalSource: 'user_rule',
        matchedRuleId: rule.id,
        updatedAt: new Date(),
      },
    });

    void checkBudgetForCategory(catRow.id).catch((err) =>
      console.error('[budgetAlerts] check failed after rule recategorize:', err),
    );

    console.log(
      `[recategorize] rule "${rule.name}" fired on ${opts.tx.id}: → ${rule.suggestCategory} (conf ${rule.confidence})`,
    );

    return {
      updated: true,
      newCategory: rule.suggestCategory,
      newMerchant: null,
      confidence: rule.confidence,
      matchedPlacesType: `user_rule:${rule.id}`,
    };
  }

  return null;
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
