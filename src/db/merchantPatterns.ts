// Pattern-learning repository. Every time the user confirms a category for a
// transaction (via the swipe / edit-tag flow), we increment a counter keyed
// on the normalized merchant. After 3 confirmations of the same merchant →
// category mapping, the pattern flips to "auto-tag active" and future
// transactions for that merchant get tagged without hitting the review queue.
//
// Schema (prisma/schema.prisma — MerchantPattern):
//   merchantNormalized  (unique key)
//   categoryId
//   hitCount
//   autoTagActive
//
// The unique constraint is on `merchantNormalized`, not on the pair
// (merchantNormalized, categoryId). That's intentional: if the user re-tags
// the same merchant with a DIFFERENT category later, we update the row
// (don't accumulate stale category mappings).

import { prisma } from './client.js';
import type { CategoryName } from '../categorize/types.js';

/**
 * Look up an auto-tag-eligible pattern for the given merchant.
 * Returns null when no pattern exists, or the pattern hasn't reached the
 * 3-confirmation threshold yet, or it's been disabled.
 */
export async function findActivePattern(
  merchantNormalized: string,
): Promise<{ category: CategoryName; hitCount: number } | null> {
  if (!merchantNormalized) return null;
  const row = await prisma.merchantPattern.findUnique({
    where: { merchantNormalized },
    include: { category: { select: { name: true } } },
  });
  if (!row) return null;
  if (!row.autoTagActive) return null;
  return {
    category: row.category.name as CategoryName,
    hitCount: row.hitCount,
  };
}

/**
 * Record a user confirmation. Idempotent: same merchant + category increments
 * the counter; same merchant + different category resets to 1 (the new
 * category becomes the leading hypothesis).
 *
 * Returns the new state after the write so the caller can log nicely.
 */
export async function recordConfirmation(args: {
  merchantNormalized: string;
  categoryId: string;
}): Promise<{ hitCount: number; autoTagActive: boolean; categoryChanged: boolean }> {
  const { merchantNormalized, categoryId } = args;
  if (!merchantNormalized) {
    return { hitCount: 0, autoTagActive: false, categoryChanged: false };
  }

  // Hit threshold — once we've seen the same merchant tagged the same way
  // 3 times, flip autoTagActive and stop bugging the user.
  const HIT_THRESHOLD = 3;

  const existing = await prisma.merchantPattern.findUnique({
    where: { merchantNormalized },
  });

  if (!existing) {
    // First time we've ever seen this merchant get tagged. Hit count = 1.
    const created = await prisma.merchantPattern.create({
      data: {
        merchantNormalized,
        categoryId,
        hitCount: 1,
        autoTagActive: false,
      },
    });
    return {
      hitCount: created.hitCount,
      autoTagActive: created.autoTagActive,
      categoryChanged: false,
    };
  }

  // Existing pattern. Two cases:
  //   - Same category: increment hitCount, maybe activate.
  //   - Different category: user changed their mind. Reset counter to 1.
  const sameCategory = existing.categoryId === categoryId;
  const nextHitCount = sameCategory ? existing.hitCount + 1 : 1;
  const nextActive = sameCategory
    ? existing.autoTagActive || nextHitCount >= HIT_THRESHOLD
    : false;
  const updated = await prisma.merchantPattern.update({
    where: { merchantNormalized },
    data: {
      categoryId,
      hitCount: nextHitCount,
      autoTagActive: nextActive,
      lastConfirmedAt: new Date(),
    },
  });
  return {
    hitCount: updated.hitCount,
    autoTagActive: updated.autoTagActive,
    categoryChanged: !sameCategory,
  };
}
