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
import { classifyVpa } from '../src/categorize/vpaShape.js';

const SOURCE_MERCHANT_KEYWORDS: Record<string, RegExp> = {
  swiggy: /swiggy|bundl/i,
  instamart: /swiggy|instamart|bundl/i,
  zomato: /zomato/i,
  amazon: /amazon|amzn/i,
  bookmyshow: /bookmyshow|bms/i,
  uber: /uber/i,
  cab: /uber|ola|rapido/i,
  travel: /makemytrip|goibibo|cleartrip|easemytrip|irctc|indigo|akasa|vistara/i,
  redbus: /redbus|redb|royal\s*rich|volvo|sleeper|seater|ksrtc|ktdc|tsrtc|apsrtc/i,
  airbnb: /airbnb/i,
  shopping: /amazon|flipkart|myntra|jiomart/i,
  grocery: /bigbasket|blinkit|zepto|dmart|reliance/i,
};

async function main() {
  const bound = await prisma.emailReceipt.findMany({
    where: { transactionId: { not: null } },
    include: {
      transaction: {
        select: { id: true, merchantRaw: true, merchantNormalized: true, vpa: true },
      },
    },
  });

  console.log(`${bound.length} bound receipts. Verifying alignment…\n`);

  let unbound = 0;
  for (const r of bound) {
    if (!r.transaction) continue;

    // Reason 1: source ↔ merchant keyword mismatch (existing guard).
    const re = SOURCE_MERCHANT_KEYWORDS[r.source];
    const text = `${r.transaction.merchantRaw} ${r.transaction.merchantNormalized}`;
    const aligned = re ? re.test(text) : false;

    // Reason 2: bound to a P2P UPI VPA. The user's "no emails for
    // offline purchases" rule — personal-shape VPAs are never online
    // merchants, so any receipt that landed on one is a wrong bind.
    const isP2P =
      r.transaction.vpa !== null && classifyVpa(r.transaction.vpa) === 'personal';

    if (aligned && !isP2P) continue;

    const reason = !aligned ? 'source_mismatch' : 'p2p_vpa';
    console.log(
      `  unbind ${r.id} (${r.source}, ${reason}) — tx merchant "${r.transaction.merchantRaw.slice(0, 40)}"`,
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
