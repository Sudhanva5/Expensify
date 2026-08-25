// Receipt ↔ transaction alignment rules. Pure — no DB, no Prisma.
//
// Extracted out of processReceiptEmail.ts because binding now runs in BOTH
// directions and the two paths must agree exactly:
//
//   receipt arrives first  → the HDFC alert lands later, and
//                            bindOrphanReceiptsNear() sweeps back for it
//   transaction arrives first → processReceiptEmail() binds on ingest
//
// The redBus booking that motivated this: redBus emailed the ticket at
// 15:06:24 and HDFC emailed the debit at 15:06:46. The receipt row was
// written 21s before the transaction row existed, the one-directional
// binder found no candidate, and nothing ever looked again — so a receipt
// with an exact amount match sat orphaned next to its transaction.
//
// Keeping the predicate here (rather than duplicating the filter in each
// direction) means the three guards can only ever be relaxed in one place.

import { classifyVpa } from '../categorize/vpaShape.js';

/** Time window between the receipt arrival and the HDFC card-debit
 *  alert. Was ±30 min originally but real-world delays push past that:
 *  Swiggy delivery emails arrive 25-40 min AFTER the bank debit, redBus
 *  sends the ticket and the tax-invoice ~10 min apart. ±90 min absorbs
 *  the long tail without pulling in unrelated same-amount debits — the
 *  binder still requires source ↔ merchant alignment AND the non-P2P
 *  guard regardless of how wide this window is.
 */
export const MATCH_WINDOW_MS = 90 * 60 * 1000;

/**
 * Ceiling for the relaxed "same amount, wider window" fallback that runs
 * when nothing matched inside MATCH_WINDOW_MS.
 *
 * This fallback used to be UNBOUNDED in time ("same amount, any time"),
 * which is only safe if amounts are near-unique. They aren't: a ₹238
 * Swiggy order looks exactly like every other ₹238 Swiggy order. Measured
 * against real history, the unbounded pass paired receipts with
 * transactions 11 to 163 DAYS apart — five wrong bindings, each of which
 * would have shown the wrong itemisation on an unrelated transaction.
 *
 * 24h keeps the thing the fallback exists for (an HDFC alert delayed past
 * 90 minutes, or a delivery email that lands the next morning) while making
 * cross-month collisions impossible.
 */
export const RELAXED_WINDOW_MS = 24 * 60 * 60 * 1000;

/**
 * Per-source merchant keywords that a receipt's matched transaction
 * MUST contain in its `merchantNormalized` or `merchantRaw`. Without
 * this, a Swiggy receipt for ₹200 could bind to ANY ₹200 outbound
 * transaction in the window — including offline kirana payments via
 * Paytm-QR that happen to have the same amount.
 */
export const SOURCE_MERCHANT_KEYWORDS: Record<string, RegExp> = {
  swiggy: /swiggy|bundl/i,
  instamart: /swiggy|instamart|bundl/i,
  zomato: /zomato/i,
  amazon: /amazon|amzn/i,
  bookmyshow: /bookmyshow|bms/i,
  uber: /uber/i,
  cab: /uber|ola|rapido/i,
  travel: /makemytrip|goibibo|cleartrip|easemytrip|irctc|indigo|akasa|vistara/i,
  // `makemytrip|mmt` is here on purpose and the asymmetry with `travel`
  // below is deliberate. MakeMyTrip owns redBus and settles some bookings
  // through its own acquirer, so a real bus ticket shows up against a payee
  // of "CAS*MAKEMYTRIP INDIA P". Ticket TV8Q64078508 could not bind for
  // that reason, and TV8K93604197 only bound because the merchant had been
  // hand-renamed "Redbus" — the guard was leaning on a user edit.
  //
  // The reverse is NOT allowed: `travel` (an MMT hotel/flight receipt) must
  // not match a REDBUS payee, or two unrelated travel bookings of the same
  // amount would pair up.
  redbus:
    /redbus|redb|makemytrip|mmt|royal\s*rich|volvo|sleeper|seater|ksrtc|ktdc|tsrtc|apsrtc/i,
  airbnb: /airbnb/i,
  shopping: /amazon|flipkart|myntra|jiomart/i,
  grocery: /bigbasket|blinkit|zepto|dmart|reliance/i,
};

/** Returns true when the transaction's merchant text aligns with the source. */
export function merchantMatchesSource(merchant: string, source: string): boolean {
  const re = SOURCE_MERCHANT_KEYWORDS[source];
  if (!re) return false; // unknown source → don't bind (safer)
  return re.test(merchant);
}

/// True when a VPA looks like a personal UPI handle — name@oksbi,
/// 9876543210@ybl, etc. P2P transfers never have a merchant receipt.
export function isPersonalUpiTransfer(vpa: string | null): boolean {
  if (!vpa) return false;
  return classifyVpa(vpa) === 'personal';
}

export interface ReceiptSide {
  amountInrMinor: bigint | null;
  receivedAt: Date;
  /** Post-override source ('instamart' rather than 'swiggy', etc.). */
  source: string;
}

export interface TransactionSide {
  amountInrMinor: bigint | null;
  direction: 'in' | 'out';
  occurredAt: Date;
  merchantRaw: string;
  merchantNormalized: string;
  vpa: string | null;
}

/**
 * May this receipt bind to this transaction?
 *
 * All of:
 *   1. Both sides carry an INR amount, and the amounts are equal
 *   2. The transaction is an outflow
 *   3. `occurredAt` within ±`windowMs` of the receipt's arrival — defaults
 *      to MATCH_WINDOW_MS; the relaxed fallback passes RELAXED_WINDOW_MS.
 *      `null` disables the check entirely and should be used only by
 *      tooling that has some other way to establish the pairing.
 *   4. Merchant ↔ source alignment — a Swiggy receipt can only bind to a
 *      transaction whose merchant text mentions Swiggy/Bundl
 *   5. Not an obvious P2P UPI transfer — a payment to a personal-shape VPA
 *      never has a merchant email receipt
 *
 * Note this says nothing about UNIQUENESS. Callers must still insist that
 * exactly one counterpart aligns before binding; a lone "these two could
 * go together" is not enough when three same-amount rows could each say it.
 */
export function receiptAlignsWithTransaction(
  receipt: ReceiptSide,
  tx: TransactionSide,
  opts: { windowMs?: number | null } = {},
): boolean {
  const { windowMs = MATCH_WINDOW_MS } = opts;

  if (receipt.amountInrMinor === null) return false;
  if (tx.amountInrMinor === null) return false;
  if (receipt.amountInrMinor !== tx.amountInrMinor) return false;
  if (tx.direction !== 'out') return false;

  if (windowMs !== null) {
    const delta = Math.abs(tx.occurredAt.getTime() - receipt.receivedAt.getTime());
    if (delta > windowMs) return false;
  }

  if (!merchantMatchesSource(`${tx.merchantRaw} ${tx.merchantNormalized}`, receipt.source)) {
    return false;
  }
  if (isPersonalUpiTransfer(tx.vpa)) return false;

  return true;
}
