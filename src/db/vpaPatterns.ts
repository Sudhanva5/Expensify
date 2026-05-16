// VPA-pattern repo. Higher-confidence sibling of MerchantPattern:
//   - keyed on VPA (much more unique than merchant name)
//   - single hit is enough to auto-tag forever after (no 3-hit floor)
//   - on confirmation, we ALSO bulk-update every existing transaction
//     with the same VPA to the new category, so re-tagging one row
//     propagates retroactively to the user's history.
//
// Categorize tier order (highest confidence first):
//   1. VpaPattern (this) — 0.99 confidence, single-hit threshold
//   2. MerchantPattern — 0.99 confidence, 3-hit threshold
//   3. Alias / autopay_alias — 0.95
//   4. VPA shape (personal) — 0.95
//   5. User rules — variable, typically 0.4-0.7

import { prisma } from './client.js';
import type { CategoryName } from '../categorize/types.js';

/** Look up an auto-tag category for a VPA. Single hit is enough. */
export async function findVpaPattern(
  vpa: string | null,
): Promise<{ category: CategoryName } | null> {
  if (!vpa) return null;
  const row = await prisma.vpaPattern.findUnique({
    where: { vpa },
    include: { category: { select: { name: true } } },
  });
  if (!row) return null;
  return { category: row.category.name as CategoryName };
}

/**
 * Record a VPA-level confirmation. Idempotent: same VPA + category
 * increments the counter; same VPA + different category overwrites
 * (the new tag becomes the truth — user changed their mind).
 *
 * Also bulk-updates every OTHER existing transaction with the same VPA
 * to point at the same category. This is the user's explicit ask:
 * "if I change the tag for a VPA, it should apply across all my rows."
 *
 * Returns counts so the caller can log how many rows got swept.
 */
export async function recordVpaConfirmation(args: {
  vpa: string;
  categoryId: string;
  /// Transaction the user just confirmed. Excluded from the bulk update
  /// (it was already updated via the PATCH handler).
  excludeTransactionId: string;
}): Promise<{ patternHits: number; rowsBackfilled: number }> {
  const { vpa, categoryId, excludeTransactionId } = args;

  // Upsert the pattern.
  const existing = await prisma.vpaPattern.findUnique({ where: { vpa } });
  const pattern = existing
    ? await prisma.vpaPattern.update({
        where: { vpa },
        data: {
          categoryId,
          hitCount:
            existing.categoryId === categoryId ? existing.hitCount + 1 : 1,
          lastConfirmedAt: new Date(),
        },
      })
    : await prisma.vpaPattern.create({
        data: { vpa, categoryId, hitCount: 1 },
      });

  // Bulk-update every other transaction with the same VPA. We touch
  // any row whose category is different from the new one (or null) —
  // this includes rows the user previously tagged differently. The
  // user's most recent action wins.
  const update = await prisma.transaction.updateMany({
    where: {
      vpa,
      id: { not: excludeTransactionId },
      OR: [
        { categoryId: null },
        { categoryId: { not: categoryId } },
      ],
    },
    data: {
      categoryId,
      signalSource: 'merchant_pattern',
      confidence: 0.99,
      status: 'resolved',
      updatedAt: new Date(),
    },
  });

  return {
    patternHits: pattern.hitCount,
    rowsBackfilled: update.count,
  };
}
