// Receipt extractors. Two layers:
//
//   • Universal — regex-only, runs on ANY merchant. Pulls amount and
//     order ID. Always tries (cheap, can't break).
//   • Merchant-specific — currently Swiggy. Plain-text parser that uses
//     stable section markers (`ORDER JOURNEY`, `BILL DETAILS`,
//     `Paid Via Bank`) to pull items + fees + addresses out of the
//     email body. Gracefully fails to null on shape changes.
//
// The pipeline tries merchant-specific first; if that fails it falls
// through to universal; if THAT fails it just stores sender + subject +
// snippet so iOS can show the deep-link card.

export interface ExtractedReceipt {
  amountInrMinor: bigint | null;
  orderId: string | null;
  items: ReceiptItem[] | null;
  fees: ReceiptFee[] | null;
  meta: Record<string, unknown> | null;
  parserVersion: string;
  /// When set, overrides the source returned by `pickExtractor`. Used by
  /// Swiggy's Instamart parser to relabel rows as source='instamart'
  /// (they share the @swiggy.in sender but render very differently).
  sourceOverride?: string;
}

export interface ReceiptItem {
  name: string;
  qty: number;
  priceInr: number; // rupees (display-friendly, not paise)
}

export interface ReceiptFee {
  name: string;
  amountInr: number;
}

const EMPTY: ExtractedReceipt = {
  amountInrMinor: null,
  orderId: null,
  items: null,
  fees: null,
  meta: null,
  parserVersion: 'generic.v1',
};

// === Universal regex extractor =========================================

/**
 * Pull amount (₹X.XX, the largest looks like "total paid") and order ID
 * from any plain-text receipt body. Works regardless of merchant.
 *
 * Strategy for amount: find every `₹X.XX` (or `Rs.X` variant), take the
 * MAX — receipts almost always have line items + a total, and the total
 * is by definition the largest.
 *
 * Strategy for order ID: try several phrasings the user might see —
 * "Order ID:", "Order #", "Order No:", "Order Number:".
 */
export function extractUniversal(plainText: string): ExtractedReceipt {
  const result: ExtractedReceipt = { ...EMPTY };

  // Amounts. Accept ₹, Rs., Rs prefixes. Capture the numeric portion.
  // Handle Indian-formatted thousands (₹1,23,456.78) by stripping commas.
  const amountRe = /(?:₹|Rs\.?|INR)\s*([0-9][0-9,]*(?:\.\d{1,2})?)/gi;
  const amounts: number[] = [];
  for (const m of plainText.matchAll(amountRe)) {
    const raw = m[1]?.replace(/,/g, '') ?? '';
    const n = Number(raw);
    if (Number.isFinite(n) && n > 0) amounts.push(n);
  }
  if (amounts.length > 0) {
    const maxRupees = Math.max(...amounts);
    result.amountInrMinor = BigInt(Math.round(maxRupees * 100));
  }

  // Order ID. Look for several common phrasings.
  const orderRe = /Order\s*(?:ID|No\.?|Number|#)\s*[:#]?\s*([A-Za-z0-9-]{6,32})/i;
  const orderMatch = plainText.match(orderRe);
  if (orderMatch?.[1]) result.orderId = orderMatch[1];

  return result;
}

// === Swiggy plain-text parser ==========================================

/**
 * Parse a Swiggy receipt's plain-text body into structured fields.
 * Anchored on three section markers that have been stable across all
 * recent Swiggy emails observed:
 *   - `ORDER JOURNEY` — restaurant + delivery addresses, both timestamped
 *   - `BILL DETAILS` — item lines + fee lines
 *   - `Paid Via Bank` (or `Paid Via UPI` etc.) — total paid
 *
 * Returns null when the body doesn't look like a Swiggy receipt (e.g.
 * marketing email, promo, status update). Caller falls back to
 * extractUniversal in that case.
 */
export function extractSwiggy(plainText: string): ExtractedReceipt | null {
  // Sanity check: must have all three section markers AND the visible
  // text must mention Swiggy. Otherwise it's not a receipt.
  const hasJourney = /ORDER\s+JOURNEY/i.test(plainText);
  const hasBill = /BILL\s+DETAILS/i.test(plainText);
  const hasPaid = /Paid\s+Via\s+\w+/i.test(plainText);
  if (!hasJourney || !hasBill || !hasPaid) return null;

  const result: ExtractedReceipt = {
    amountInrMinor: null,
    orderId: null,
    items: [],
    fees: [],
    meta: {},
    parserVersion: 'swiggy.v1',
  };

  // Order ID — Swiggy uses "Order ID: 237745656192462"
  const orderRe = /Order\s*ID\s*:?\s*(\d{8,})/i;
  const orderMatch = plainText.match(orderRe);
  if (orderMatch?.[1]) result.orderId = orderMatch[1];

  // Total — the line "Paid Via <X> ₹308.00"
  const totalRe = /Paid\s+Via\s+\w+\s*₹?\s*([0-9][0-9,]*(?:\.\d{1,2})?)/i;
  const totalMatch = plainText.match(totalRe);
  if (totalMatch?.[1]) {
    const n = Number(totalMatch[1].replace(/,/g, ''));
    if (Number.isFinite(n) && n > 0) {
      result.amountInrMinor = BigInt(Math.round(n * 100));
    }
  }

  // Carve out the BILL DETAILS section. Spans from "BILL DETAILS" to
  // "Paid Via <X>". Lines inside are either items (with optional `xN` qty)
  // or fees ("Platform fee with GST", "Taxes", "Delivery Fee").
  const billMatch = plainText.match(/BILL\s+DETAILS\s*([\s\S]*?)Paid\s+Via\s+\w+/i);
  if (billMatch?.[1]) {
    const bill = billMatch[1];
    // Each line is roughly "<item or fee name> [xN] ₹<amount>". Split on
    // ₹ — every receipt-line ends with an amount; preceding text is the
    // label. We rebuild lines from "<label> ₹<amount>".
    const lineRe = /([A-Za-z][^₹]*?)\s*₹\s*([0-9][0-9,]*(?:\.\d{1,2})?)\s*(FREE)?/g;
    for (const m of bill.matchAll(lineRe)) {
      const rawLabel = (m[1] ?? '').trim();
      const amount = Number((m[2] ?? '').replace(/,/g, ''));
      if (!rawLabel || !Number.isFinite(amount)) continue;

      // Item-line shape: "<name> xN" or "<name> x N". Pull qty if present.
      const qtyMatch = rawLabel.match(/^(.*?)\s+x\s*(\d+)\s*$/i);
      if (qtyMatch?.[1] && qtyMatch[2]) {
        result.items!.push({
          name: qtyMatch[1].trim(),
          qty: Number(qtyMatch[2]),
          priceInr: amount,
        });
      } else {
        // Fee row — anything that wasn't shaped as an item with quantity.
        result.fees!.push({ name: rawLabel, amountInr: amount });
      }
    }
  }

  // ORDER JOURNEY — two address lines, both timestamped. We extract them
  // as raw strings; iOS renders them verbatim. Format we've observed:
  //   <Restaurant Name> <restaurant address>, <Mon DD, H:MM AM/PM>
  //   <Recipient Name> <delivery address>, <Mon DD, H:MM AM/PM>
  const journeyMatch = plainText.match(/ORDER\s+JOURNEY\s*([\s\S]*?)(?:Order\s*ID|$)/i);
  if (journeyMatch?.[1]) {
    const journey = journeyMatch[1].trim();
    // Split on the timestamp tail (e.g. "May 14, 9:57 PM"). Each entry's
    // last token before split is its timestamp.
    const tsRe =
      /(.+?)\s+((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2},\s*\d{1,2}:\d{2}\s*(?:AM|PM))/gi;
    const entries: Array<{ text: string; timestamp: string }> = [];
    for (const m of journey.matchAll(tsRe)) {
      if (m[1] && m[2]) {
        entries.push({ text: m[1].trim(), timestamp: m[2] });
      }
    }
    if (entries.length >= 1) {
      result.meta!['journeyFrom'] = entries[0];
    }
    if (entries.length >= 2) {
      result.meta!['journeyTo'] = entries[1];
    }
  }

  // If we managed to extract NOTHING useful, return null so caller can
  // fall through to the universal extractor.
  if (
    result.amountInrMinor === null &&
    result.orderId === null &&
    result.items!.length === 0 &&
    result.fees!.length === 0
  ) {
    return null;
  }

  return result;
}

// === Swiggy Instamart parser ==========================================

/**
 * Parse a Swiggy Instamart receipt's plain-text body. Instamart shares
 * the @swiggy.in sender with food orders but renders very differently:
 * no `ORDER JOURNEY` section, no `Paid Via Bank` total — instead the
 * structure is `Order Items`, `Order Summary`, `Grand Total`.
 *
 * Section markers anchored on:
 *   - `Instamart order id: NNNN`
 *   - `Order Items` … `Order Summary`  (item lines: `N x <name> ₹<amt>`)
 *   - `Order Summary` … `Grand Total`  (fee lines)
 *   - `Grand Total ₹<amt>`
 *
 * Also pulls the `Deliver To:` address into `meta.deliveryAddress`.
 *
 * Returns null when the body doesn't look like an Instamart receipt
 * (caller chains to the food parser, then universal).
 */
export function extractInstamart(plainText: string): ExtractedReceipt | null {
  // Sanity check — these three markers are stable across Instamart
  // emails seen so far. If any are missing, this isn't an Instamart
  // receipt (might be promo, order-placed status, etc.).
  const hasOrderItems = /Order\s+Items/i.test(plainText);
  const hasOrderSummary = /Order\s+Summary/i.test(plainText);
  const hasGrandTotal = /Grand\s+Total/i.test(plainText);
  const hasInstamartLabel = /Instamart/i.test(plainText);
  if (!hasOrderItems || !hasOrderSummary || !hasGrandTotal || !hasInstamartLabel) {
    return null;
  }

  const result: ExtractedReceipt = {
    amountInrMinor: null,
    orderId: null,
    items: [],
    fees: [],
    meta: {},
    parserVersion: 'instamart.v1',
    sourceOverride: 'instamart',
  };

  // Order ID — "Instamart order id: 237274058243810" (case-insensitive)
  const orderRe = /(?:Instamart\s+)?order\s+id\s*:?\s*(\d{8,})/i;
  const orderMatch = plainText.match(orderRe);
  if (orderMatch?.[1]) result.orderId = orderMatch[1];

  // Grand Total — "Grand Total ₹547.00"
  const totalRe = /Grand\s+Total\s*₹?\s*([0-9][0-9,]*(?:\.\d{1,2})?)/i;
  const totalMatch = plainText.match(totalRe);
  if (totalMatch?.[1]) {
    const n = Number(totalMatch[1].replace(/,/g, ''));
    if (Number.isFinite(n) && n > 0) {
      result.amountInrMinor = BigInt(Math.round(n * 100));
    }
  }

  // Items between "Order Items" and "Order Summary". Each item line:
  //   "1 x Ariel Lavender Power Gel Liquid Detergent Top Load   ₹536.00"
  const itemsMatch = plainText.match(/Order\s+Items\s*([\s\S]*?)Order\s+Summary/i);
  if (itemsMatch?.[1]) {
    const itemRe =
      /(\d+)\s*x\s+([A-Za-z][^₹\n]+?)\s*₹\s*([0-9][0-9,]*(?:\.\d{1,2})?)/g;
    for (const m of itemsMatch[1].matchAll(itemRe)) {
      const qty = Number(m[1]);
      const name = (m[2] ?? '').trim();
      const priceInr = Number((m[3] ?? '').replace(/,/g, ''));
      if (!name || !Number.isFinite(qty) || !Number.isFinite(priceInr)) continue;
      result.items!.push({ name, qty, priceInr });
    }
  }

  // Fees between "Order Summary" and "Grand Total". Each line:
  //   "Handling Fee   ₹11.00"
  //   "Delivery Partner Fee   ₹0.00"
  //   "Item Bill   ₹536.00"  ← skip; this is the items total
  const feesMatch = plainText.match(/Order\s+Summary\s*([\s\S]*?)Grand\s+Total/i);
  if (feesMatch?.[1]) {
    const feeRe = /([A-Za-z][^₹\n]+?)\s*₹\s*([0-9][0-9,]*(?:\.\d{1,2})?)/g;
    for (const m of feesMatch[1].matchAll(feeRe)) {
      const name = (m[1] ?? '').trim();
      const amount = Number((m[2] ?? '').replace(/,/g, ''));
      if (!name || !Number.isFinite(amount)) continue;
      // "Item Bill" is the sum of item prices; not a real fee.
      if (/^Item\s+Bill$/i.test(name)) continue;
      result.fees!.push({ name, amountInr: amount });
    }
  }

  // Delivery address — "Deliver To:" followed by the address line.
  const addrMatch = plainText.match(/Deliver\s+To\s*:?\s*([^\n]{10,})/i);
  if (addrMatch?.[1]) {
    result.meta!['deliveryAddress'] = addrMatch[1].trim();
  }

  // Reject if NOTHING useful came out — caller falls through to universal.
  if (
    result.amountInrMinor === null &&
    result.orderId === null &&
    result.items!.length === 0
  ) {
    return null;
  }

  return result;
}

// === Sender → extractor router =========================================

/**
 * Pick the right extractor for a sender. Returns the merchant-specific
 * extractor when one exists; falls back to universal otherwise.
 */
export function pickExtractor(fromAddress: string): {
  source: string;
  extract: (plainText: string) => ExtractedReceipt;
} {
  const addr = fromAddress.toLowerCase();
  if (addr.includes('swiggy.in') || addr.includes('@swiggy.')) {
    return {
      source: 'swiggy',
      // Two Swiggy formats: food orders (ORDER JOURNEY / BILL DETAILS /
      // Paid Via Bank) and Instamart (Order Items / Order Summary /
      // Grand Total). Try food first, then Instamart, then universal
      // fallback. Instamart's parser sets sourceOverride='instamart'
      // so iOS can render the right brand label.
      extract: (text) =>
        extractSwiggy(text) ?? extractInstamart(text) ?? extractUniversal(text),
    };
  }
  // Other merchants currently use the universal extractor. Add per-
  // merchant parsers here as the data warrants.
  if (addr.includes('zomato.com') || addr.includes('@zomato.')) {
    return { source: 'zomato', extract: extractUniversal };
  }
  if (addr.includes('amazon.in') || addr.includes('amazon.')) {
    return { source: 'amazon', extract: extractUniversal };
  }
  if (addr.includes('bookmyshow.')) {
    return { source: 'bookmyshow', extract: extractUniversal };
  }
  if (addr.includes('uber.com')) {
    return { source: 'uber', extract: extractUniversal };
  }
  if (addr.includes('olacabs.') || addr.includes('rapido.')) {
    return { source: 'cab', extract: extractUniversal };
  }
  if (addr.includes('makemytrip.') || addr.includes('goibibo.') || addr.includes('cleartrip.')) {
    return { source: 'travel', extract: extractUniversal };
  }
  if (addr.includes('airbnb.')) {
    return { source: 'airbnb', extract: extractUniversal };
  }
  if (addr.includes('flipkart.') || addr.includes('myntra.') || addr.includes('jiomart.')) {
    return { source: 'shopping', extract: extractUniversal };
  }
  if (addr.includes('blinkit.') || addr.includes('zepto.') || addr.includes('bigbasket.')) {
    return { source: 'grocery', extract: extractUniversal };
  }
  return { source: 'generic', extract: extractUniversal };
}

/**
 * Known receipt-emitting sender domains. The Gmail-watch handler uses
 * this to decide whether an inbound email is a receipt vs. just regular
 * mail. Keep it tight — false positives clutter the EmailReceipt table.
 */
export const RECEIPT_SENDER_DOMAINS = [
  'swiggy.in',
  'zomato.com',
  'amazon.in',
  'amazon.com',
  'bookmyshow.com',
  'uber.com',
  'olacabs.com',
  'rapido.bike',
  'makemytrip.com',
  'goibibo.com',
  'cleartrip.com',
  'airbnb.com',
  'flipkart.com',
  'myntra.com',
  'jiomart.com',
  'bigbasket.com',
  'blinkit.com',
  'zepto.com',
];

export function isReceiptSender(fromAddress: string | null): boolean {
  if (!fromAddress) return false;
  const lower = fromAddress.toLowerCase();
  return RECEIPT_SENDER_DOMAINS.some((d) => lower.includes(d));
}
