// Walk EmailReceipt rows that currently have a transactionId set and
// verify the receipt's source matches the bound transaction's merchant
// text. Unbind any that fail the alignment check — those are the
// "random ₹200 Swiggy email got tagged to Thimmegowda's Paytm-QR row"
// class of bug.
//
// Safe to re-run. Doesn't delete receipts; just clears `transactionId`.
//
// Usage: DATABASE_URL=... npx tsx scripts/unbind-mismatched-receipts.ts

import { prisma } from '../src/db/client.js';

const SOURCE_MERCHANT_KEYWORDS: Record<string, RegExp> = {
  swiggy: /swiggy|bundl/i,
  instamart: /swiggy|instamart|bundl/i,
  zomato: /zomato/i,
  amazon: /amazon|amzn/i,
  bookmyshow: /bookmyshow|bms/i,
  uber: /uber/i,
  cab: /uber|ola|rapido/i,
  travel: /makemytrip|goibibo|cleartrip|easemytrip|irctc|indigo|akasa|vistara/i,
  airbnb: /airbnb/i,
  shopping: /amazon|flipkart|myntra|jiomart/i,
  grocery: /bigbasket|blinkit|zepto|dmart|reliance/i,
};

async function main() {
  const bound = await prisma.emailReceipt.findMany({
    where: { transactionId: { not: null } },
    include: {
      transaction: {
        select: { id: true, merchantRaw: true, merchantNormalized: true },
      },
    },
  });

  console.log(`${bound.length} bound receipts. Verifying alignment…\n`);

  let unbound = 0;
  for (const r of bound) {
    if (!r.transaction) continue;
    const re = SOURCE_MERCHANT_KEYWORDS[r.source];
    const text = `${r.transaction.merchantRaw} ${r.transaction.merchantNormalized}`;
    const aligned = re ? re.test(text) : false;
    if (aligned) continue;

    console.log(
      `  unbind ${r.id} (${r.source}) — tx merchant "${r.transaction.merchantRaw.slice(0, 40)}" doesn't match`,
    );
    await prisma.emailReceipt.update({
      where: { id: r.id },
      data: { transactionId: null },
    });
    unbound++;
  }

  console.log(`\nUnbound ${unbound} of ${bound.length} mis-bound receipts.`);
}

main()
  .catch((err) => { console.error(err); process.exit(1); })
  .finally(async () => { await prisma.$disconnect(); });
