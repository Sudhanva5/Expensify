// Seed script — loads the 7 V1 categories, the cross-cutting "international" tag,
// merchant aliases, and autopay aliases from src/categorize/seed.ts into the database.
//
// Run via: npm run db:seed
// Idempotent: safe to run repeatedly. Uses upsert on every row.

import { PrismaClient } from '@prisma/client';
import {
  SEED_ALIASES,
  SEED_AUTOPAY_ALIASES,
  ROUTING_PREFIXES,
} from '../src/categorize/seed.js';
import { CATEGORIES } from '../src/categorize/types.js';

const prisma = new PrismaClient();

async function main() {
  console.log('Seeding categories...');
  for (const name of CATEGORIES) {
    await prisma.category.upsert({
      where: { name },
      update: {},
      create: { name },
    });
  }
  console.log(`  ${CATEGORIES.length} categories ensured`);

  console.log('Seeding tags...');
  await prisma.tag.upsert({
    where: { name: 'international' },
    update: {},
    create: { name: 'international' },
  });
  console.log('  1 tag ensured');

  // Build a name → id lookup so we can wire FK relations
  const categoryRows = await prisma.category.findMany();
  const categoryIdByName = new Map(categoryRows.map((c) => [c.name, c.id]));

  console.log('Seeding merchant aliases...');
  let aliasCount = 0;
  for (const a of SEED_ALIASES) {
    const categoryId = a.category ? categoryIdByName.get(a.category) ?? null : null;
    await prisma.merchantAlias.upsert({
      where: { rawPattern: a.pattern },
      update: { canonical: a.canonical, matchType: a.matchType, categoryId },
      create: {
        rawPattern: a.pattern,
        canonical: a.canonical,
        matchType: a.matchType,
        categoryId,
      },
    });
    aliasCount++;
  }
  console.log(`  ${aliasCount} aliases ensured`);

  console.log('Seeding autopay aliases (as MerchantAlias rows tagged "autopay:")...');
  // We reuse MerchantAlias for autopay too, prefixing the pattern with "autopay:"
  // to keep them in the same table without colliding. The categorize layer's
  // SEED_AUTOPAY_ALIASES is the canonical source for now; once the worker is
  // wired we'll read these from the DB instead of re-importing the constant.
  let autopayCount = 0;
  for (const a of SEED_AUTOPAY_ALIASES) {
    const key = `autopay:${a.pattern}`;
    const categoryId = categoryIdByName.get(a.category)!;
    await prisma.merchantAlias.upsert({
      where: { rawPattern: key },
      update: { canonical: a.pattern, matchType: a.matchType, categoryId, notes: 'autopay' },
      create: {
        rawPattern: key,
        canonical: a.pattern,
        matchType: a.matchType,
        categoryId,
        notes: 'autopay',
      },
    });
    autopayCount++;
  }
  console.log(`  ${autopayCount} autopay aliases ensured`);

  // Sanity counts
  const counts = {
    categories: await prisma.category.count(),
    tags: await prisma.tag.count(),
    aliases: await prisma.merchantAlias.count(),
  };
  console.log('\nFinal counts:', counts);

  // Reference: routing prefixes are constants for now; not stored in DB
  console.log(`\nRouting prefixes (in code): ${ROUTING_PREFIXES.join(', ')}`);
}

main()
  .then(async () => {
    await prisma.$disconnect();
  })
  .catch(async (err) => {
    console.error(err);
    await prisma.$disconnect();
    process.exit(1);
  });
