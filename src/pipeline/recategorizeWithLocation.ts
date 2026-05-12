// Re-categorize a transaction once iOS has uploaded its location.
//
// Flow:
//   1. Pull the latest row from DB (skip if already resolved or not_applicable)
//   2. Query Google Places API for businesses within 100m
//   3. Feed candidates + transaction context to Groq
//   4. If Groq returns confidence >= 0.95, update the row:
//        - merchantNormalized = Places display name (premium UI shows this)
//        - categoryId = matched category
//        - status = resolved (drops out of review queue)
//   5. Otherwise leave row pending_review for the user to swipe
//
// Called fire-and-forget from POST /transactions/:id/location so the location
// upload returns 200 immediately — re-categorize runs in the background.

import { prisma } from '../db/client.js';
import { buildOptionalPlacesClient } from '../services/places.js';
import { HttpGroqCategorizer } from '../categorize/groq.js';

const AUTO_TAG_THRESHOLD = 0.95;

export type RecategorizeOutcome =
  | { updated: true; newCategory: string; newMerchant: string | null; confidence: number }
  | { updated: false; reason: string };

export async function recategorizeWithLocation(opts: {
  transactionId: string;
  lat: number;
  lng: number;
}): Promise<RecategorizeOutcome> {
  const places = buildOptionalPlacesClient();
  if (!places) return { updated: false, reason: 'places_not_configured' };

  const groqKey = process.env['GROQ_API_KEY'];
  if (!groqKey) return { updated: false, reason: 'groq_not_configured' };
  const groq = new HttpGroqCategorizer({ apiKey: groqKey });

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

  // Ask Groq to pick the most likely candidate
  const groqInput = {
    merchantRaw: tx.merchantRaw,
    merchantNormalized: tx.merchantNormalized,
    vpa: tx.vpa,
    amountInr:
      tx.amountInrMinor !== null
        ? Number(tx.amountInrMinor) / 100
        : Number(tx.amountMinor) / 100,
    occurredAt: tx.occurredAt,
    direction: tx.direction as 'in' | 'out',
    instrument: tx.instrument,
    isAutopay: false,
    placesContext: candidates,
  };

  let groqResult;
  try {
    groqResult = await groq.categorize(groqInput);
  } catch (err) {
    console.error('[recategorize] Groq call failed:', err);
    return { updated: false, reason: 'groq_call_failed' };
  }

  if (groqResult.category === null) {
    return { updated: false, reason: 'groq_no_category' };
  }

  if (groqResult.confidence < AUTO_TAG_THRESHOLD) {
    return { updated: false, reason: `low_confidence_${groqResult.confidence.toFixed(2)}` };
  }

  // Resolve merchant name: prefer Groq's pick if it matches one of the
  // Places candidates exactly; otherwise fall back to the closest candidate's
  // name; if neither, leave merchantNormalized alone.
  const resolvedMerchant =
    candidates.find((c) => c.name === groqResult.merchantName)?.name ??
    candidates[0]?.name ??
    null;

  const catRow = await prisma.category.findUnique({
    where: { name: groqResult.category },
  });
  if (!catRow) {
    return { updated: false, reason: `unknown_category_${groqResult.category}` };
  }

  await prisma.transaction.update({
    where: { id: tx.id },
    data: {
      ...(resolvedMerchant ? { merchantNormalized: resolvedMerchant } : {}),
      categoryId: catRow.id,
      status: 'resolved',
      confidence: groqResult.confidence,
      signalSource: 'brave_groq', // reuse existing enum slot; Places+Groq is conceptually the same role
      updatedAt: new Date(),
    },
  });

  console.log(
    `[recategorize] resolved ${tx.id}: ${resolvedMerchant ?? '(no merchant change)'} → ${groqResult.category} (${groqResult.confidence})`,
  );

  return {
    updated: true,
    newCategory: groqResult.category,
    newMerchant: resolvedMerchant,
    confidence: groqResult.confidence,
  };
}
