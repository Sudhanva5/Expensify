// One-off seed: create the "near Scaler School of Technology → Travel"
// rule. Captures the user's actual pattern — every Rapido / Uber / Ola
// pickup hailed from inside the campus is a ₹100-500 UPI debit to a
// driver's personal VPA. With the rule in place, recategorizeWithLocation
// auto-tags those rows the moment the GPS uploads.
//
//   npx tsx scripts/seed-office-rule.ts
//
// Idempotent: upserts by name. Re-running is safe; the rule simply
// gets refreshed to the current coordinates / amount window.

import { prisma } from '../src/db/client.js';
import { Prisma } from '@prisma/client';

const RULE_NAME = 'Near Scaler office → Travel';
const SCALER_LAT = 12.8386185;
const SCALER_LNG = 77.6646949;
const RADIUS_METERS = 100;
const AMOUNT_MIN = 100;
const AMOUNT_MAX = 500;
const CATEGORY = 'Travel';
const CONFIDENCE = 0.95;

async function main() {
  const cat = await prisma.category.findUnique({ where: { name: CATEGORY } });
  if (!cat) throw new Error(`Category "${CATEGORY}" not found — seed the categories table first.`);

  const conditions = {
    direction: 'out',
    amountBetween: [AMOUNT_MIN, AMOUNT_MAX],
    locationWithinRadius: {
      lat: SCALER_LAT,
      lng: SCALER_LNG,
      meters: RADIUS_METERS,
    },
  };

  // Idempotent upsert by rule name. UserRule doesn't have a uniqueness
  // constraint on name, so we delete-then-create to keep it clean.
  const existing = await prisma.userRule.findFirst({ where: { name: RULE_NAME } });
  if (existing) {
    await prisma.userRule.update({
      where: { id: existing.id },
      data: {
        priority: 100,
        enabled: true,
        conditions: conditions as unknown as Prisma.InputJsonValue,
        categoryId: cat.id,
        defaultConfidence: new Prisma.Decimal(CONFIDENCE),
      },
    });
    console.log(`[seed-office-rule] updated existing rule ${existing.id}`);
  } else {
    const created = await prisma.userRule.create({
      data: {
        name: RULE_NAME,
        priority: 100,
        enabled: true,
        conditions: conditions as unknown as Prisma.InputJsonValue,
        categoryId: cat.id,
        defaultConfidence: new Prisma.Decimal(CONFIDENCE),
      },
    });
    console.log(`[seed-office-rule] created rule ${created.id}`);
  }
  console.log(`  conditions: ₹${AMOUNT_MIN}-${AMOUNT_MAX} within ${RADIUS_METERS}m of ${SCALER_LAT}, ${SCALER_LNG}`);
  console.log(`  category: ${CATEGORY} (conf ${CONFIDENCE})`);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error('[seed-office-rule] failed:', err);
    process.exit(1);
  });
