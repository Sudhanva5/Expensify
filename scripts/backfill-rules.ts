// Backfill: walk every transaction with GPS and re-evaluate enabled
// user rules against it. Apply the highest-priority rule that fires
// at ≥ AUTO_TAG_CONFIDENCE_THRESHOLD.
//
// Why this is needed: when the user adds a new rule (or fixes the GPS
// coordinates on an existing one), recategorizeWithLocation has
// already run on every historical row and won't re-trigger. This
// script does the catch-up sweep.
//
//   npx tsx scripts/backfill-rules.ts            # dry-run, no writes
//   npx tsx scripts/backfill-rules.ts --apply    # commit changes
//
// Idempotent: rules with confidence < threshold are skipped, and
// rows already matching a rule's outcome are no-ops.

import { prisma } from '../src/db/client.js';
import { listEnabledRules } from '../src/db/userRules.js';
import { evaluateRule } from '../src/categorize/rules.js';
import { classifyVpa } from '../src/categorize/vpaShape.js';
import { AUTO_TAG_CONFIDENCE_THRESHOLD } from '../src/categorize/types.js';
import type { ParsedTransaction } from '../src/parsers/hdfc/index.js';

const APPLY = process.argv.includes('--apply');

async function main() {
  const rules = await listEnabledRules();
  if (rules.length === 0) {
    console.log('[backfill-rules] no enabled rules; nothing to do.');
    return;
  }
  console.log(`[backfill-rules] ${rules.length} enabled rule(s); apply=${APPLY}`);

  const txs = await prisma.transaction.findMany({
    where: {
      direction: 'out',
      locationLat: { not: null },
      locationLng: { not: null },
    },
    select: {
      id: true,
      merchantRaw: true,
      merchantNormalized: true,
      vpa: true,
      direction: true,
      instrument: true,
      amountMinor: true,
      amountInrMinor: true,
      currency: true,
      occurredAt: true,
      locationLat: true,
      locationLng: true,
      categoryId: true,
      signalSource: true,
      status: true,
      category: { select: { name: true } },
    },
  });
  console.log(`[backfill-rules] scanning ${txs.length} located outflow transaction(s)`);

  // Cache category lookups so we don't re-query for every row.
  const categoryByName = new Map<string, string>();

  let matched = 0;
  let updated = 0;
  let skipped = 0;
  for (const tx of txs) {
    const parsed: ParsedTransaction = {
      template: 'upi_debit',
      direction: tx.direction,
      instrument: tx.instrument,
      amountMinor: tx.amountMinor,
      currency: tx.currency,
      amountInrMinor: tx.amountInrMinor,
      bankConvertedRate: null,
      merchantRaw: tx.merchantRaw,
      vpa: tx.vpa,
      occurredAt: tx.occurredAt,
      externalRef: null,
      isAutopay: false,
    };
    const ctx = {
      aliasMatched: tx.signalSource === 'alias',
      vpaShape: tx.vpa ? classifyVpa(tx.vpa) : ('unknown' as const),
      txLat: tx.locationLat ? Number(tx.locationLat) : undefined,
      txLng: tx.locationLng ? Number(tx.locationLng) : undefined,
    };

    let fired: typeof rules[number] | null = null;
    for (const r of rules) {
      if (r.confidence < AUTO_TAG_CONFIDENCE_THRESHOLD) continue;
      if (evaluateRule(r, parsed, ctx)) {
        fired = r;
        break;
      }
    }
    if (!fired) continue;
    matched++;

    let categoryId = categoryByName.get(fired.suggestCategory);
    if (!categoryId) {
      const cat = await prisma.category.findUnique({ where: { name: fired.suggestCategory } });
      if (!cat) {
        console.warn(`  skip ${tx.id}: category "${fired.suggestCategory}" not found`);
        skipped++;
        continue;
      }
      categoryId = cat.id;
      categoryByName.set(fired.suggestCategory, categoryId);
    }

    const currentName = tx.category?.name ?? 'null';
    const sameAlready = tx.categoryId === categoryId && tx.signalSource === 'user_rule';
    if (sameAlready) {
      skipped++;
      continue;
    }

    console.log(
      `  ${APPLY ? 'apply' : 'would apply'}: ${tx.id} (${currentName} → ${fired.suggestCategory}) via rule "${fired.name}"`,
    );

    if (APPLY) {
      await prisma.transaction.update({
        where: { id: tx.id },
        data: {
          categoryId,
          status: 'resolved',
          confidence: fired.confidence,
          signalSource: 'user_rule',
          matchedRuleId: fired.id,
          updatedAt: new Date(),
        },
      });
      updated++;
    }
  }

  console.log(
    `[backfill-rules] matched=${matched} updated=${updated} skipped=${skipped}` +
      (APPLY ? '' : '   (dry-run; rerun with --apply to commit)'),
  );
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error('[backfill-rules] failed:', err);
    process.exit(1);
  });
