// One-shot: delete every EmailReceipt row. Safe — receipts are derived
// from Gmail, can always be reconstructed via backfill-receipts.ts.
// Used to re-run the backfill after improving extractors.

import { prisma } from '../src/db/client.js';

async function main() {
  const r = await prisma.emailReceipt.deleteMany();
  console.log(`Deleted ${r.count} EmailReceipt rows.`);
}

main()
  .catch((err) => {
    console.error(err);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
