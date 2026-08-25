// Online-merchant detector.
//
// SCOPE — this used to gate whether we asked iOS for GPS at all. It no
// longer does. Every outflow now goes through the location round-trip
// (see db/transactions.ts), because the classifier is not good enough to
// be trusted with that decision: "paytm-57338997" is a petrol pump in
// Electronic City and "PHP*REDBUS" is a bus booked from the sofa, and the
// old rules got both backwards.
//
// What it still decides is narrower and safer: may the Places pass
// silently RENAME + RETAG this row from whatever shop happens to be
// nearby? For a charge with no physical storefront the answer is no. The
// original production bug: "NAME-CHEAP.COM* S0EXHV" became "Groceries /
// Vishal Mega Mart" because the user stood near a supermarket when their
// domain renewed. Delivery brands are the same shape — a Swiggy order
// renamed to the restaurant across the road from your flat is wrong in
// exactly the same way.
//
// Rows we flag still collect GPS and still get nearby-place SUGGESTIONS
// persisted for the iOS picker. The user can claim one in a tap. We just
// refuse to do it for them.
//
// A PAYMENT RAIL IS NOT A SIGNAL. Paytm, PhonePe, Razorpay, PayU, GPay,
// CRED and Amazon Pay all route in-person QR terminals as happily as they
// route web checkouts, so their prefixes say nothing about whether a
// storefront exists. They are deliberately absent from the list below —
// adding one back re-breaks every pump, kirana and cafe behind that rail.

/**
 * Brands whose charges have no physical storefront to snap to: SaaS,
 * streaming, hosting, brokerages, and delivery / marketplace / travel
 * platforms that come to the customer rather than the reverse.
 *
 * Multi-word entries carry their own `\s*`. Longest-first ordering is
 * applied when the regex is built so "REDBUS" reports itself rather than
 * the shorter "REDB".
 */
const ONLINE_BRANDS: string[] = [
  // Hosting / infra / dev tools
  'NAME-CHEAP', 'NAMECHEAP', 'GODADDY', 'CLOUDFLR', 'VERCEL', 'RAILWAY',
  'HEROKU', 'RENDER', 'FLY\\.IO', 'AWS', 'GOOGLE\\s*CLOUD', 'GCP',
  'GITHUB', 'GITLAB', 'FIGMA', 'NOTION', 'LINEAR', 'SLACK', 'ZOOM', 'DROPBOX',
  // AI / software subscriptions
  'ANTHROPIC', 'CLAUDE', 'OPENAI', 'CHATGPT', 'CURSOR', 'ADOBE',
  'MICROSOFT', 'MSFT', 'MS365', 'M365', 'OFFICE\\s*365',
  'APPLE\\.COM', 'ITUNES', 'ICLOUD', 'GOOGLE\\s*ONE', 'GOOGLE',
  // Streaming / media / creators
  'NETFLIX', 'SPOTIFY', 'YOUTUBE', 'YT\\s*PREMIUM', 'HOTSTAR', 'DISNEY',
  'SONY\\s*LIV', 'SONYLIV', 'ZEE5', 'VOOT', 'TWITCH', 'DISCORD', 'TELEGRAM',
  'SUBSTACK', 'PATREON', 'MEDIUM', 'TIMES\\s*PRIME',
  // ISP / DTH
  'JIO\\s*FIBER', 'AIRTEL\\s*XSTREAM', 'TATA\\s*PLAY',
  // Brokerages / investing
  'ZERODHA', 'GROWW', 'UPSTOX', 'ANGELONE', 'KUVERA', 'FYERS',
  'FIDELITY', 'VANGUARD', 'COINBASE', 'BINANCE', 'WAZIRX', 'WAZIR',
  'COINDCX', 'COIN\\s*DCX',
  // Education
  'UDEMY', 'COURSERA', 'EDX', 'UNACADEMY', 'BYJU', 'VEDANTU',
  // News
  'FT\\.COM', 'WSJ', 'NYTIMES', 'ECONOMIST', 'BLOOMBERG', 'REUTERS',
  'FORBES', 'SCROLL', 'THEPRINT', 'THE\\s*PRINT', 'TIME\\s*MAGAZINE',
  // Gaming
  'SQUARE\\s*ENIX', 'EPIC\\s*GAMES', 'EPICGAMES', 'STEAM', 'UBISOFT',
  'PLAYSTATION', 'XBOX', 'NINTENDO',
  // Food delivery + quick commerce — the order comes to you
  'SWIGGY', 'BUNDL', 'ZOMATO', 'BLINKIT', 'INSTAMART', 'BIGBASKET',
  'ZEPTO', 'DUNZO', 'FRESHTOHOME', 'LICIOUS',
  // Ride hailing + travel booking — no storefront at the tap point
  'UBER', 'OLA', 'RAPIDO', 'REDBUS', 'REDB', 'MAKEMYTRIP', 'GOIBIBO',
  'CLEARTRIP', 'EASEMYTRIP', 'IRCTC', 'INDIGO', 'AKASA', 'VISTARA',
  'AIRBNB',
  // Marketplaces / e-commerce
  'AMAZON', 'AMZN', 'FLIPKART', 'FLIPK', 'MYNTRA', 'MEESHO', 'JIOMART',
  'NYKAA', 'AJIO', 'TATACLIQ', 'TATA\\s*CLIQ', 'FIRSTCRY',
  'BOOKMYSHOW', 'BMS',
  // Online pharmacy / telehealth
  'PHARMEASY', 'PHARM\\s*EASY', 'NETMEDS', '1MG', 'PRACTO',
  // At-home services booked in-app
  'URBANCOMPANY', 'URBAN\\s*COMPANY', 'TASKBOB', 'HOUSEJOY',
  // Bill aggregators — a utility bill has no storefront either.
  // Note "CRED\s*CLUB" but NOT bare "CRED": the app paying your card bill
  // has no storefront, while a shop reached through the CRED rail does.
  'BLLG', 'BBPS', 'CRED\\s*CLUB',
];

/**
 * Brand token anywhere in the payee text, not just at the start.
 *
 * HDFC puts the acquirer's prefix first about half the time ("PHP*REDBUS",
 * "PTM*SWIGGY"), so the old `^`-anchored pattern never reached the brand.
 * It also demanded a TRAILING delimiter, which meant even a bare "REDBUS"
 * failed to match.
 *
 * Both boundaries are `[^A-Za-z]`-or-string-edge rather than a fixed
 * delimiter set. That admits `*`, spaces, hyphens, slashes, dots and
 * digits ("redbus32") while still refusing to match inside a longer word —
 * "SRI CREDIT SOCIETY", "UBERTO FASHIONS" and "OLAVAKKOT STORES" are real
 * payees that a naive substring match would wrongly flag.
 */
const ONLINE_BRAND_RE = new RegExp(
  `(?:^|[^A-Za-z])(${[...ONLINE_BRANDS]
    .sort((a, b) => b.length - a.length)
    .join('|')})(?=$|[^A-Za-z])`,
  'i',
);

// "domain.tld" appearing in the merchant string — strong tell for an online charge.
// We only match domain-looking patterns (something + dot + 2-5 letter TLD) to
// avoid false positives like "MR. SMITH".
const TLD_RE =
  /\b[a-z0-9-]{2,}\.(com|in|co|ai|app|io|net|org|me|tech|space|dev|cloud|store|live|tv|fm|gg)\b/i;

export interface OnlineCheckResult {
  isOnline: boolean;
  reason?: 'online_brand' | 'tld_substring';
  matched?: string;
}

/**
 * Decide whether a transaction's payee text names a merchant with no
 * physical storefront — i.e. whether Places is allowed to auto-rename it.
 *
 * Heuristic — favours false negatives over false positives. A false
 * negative costs one unnecessary Places rename the user can correct; a
 * false positive means a real shop never gets auto-resolved and the user
 * types the name by hand. Since this no longer gates GPS collection, both
 * error modes are recoverable — which is exactly why the GPS decision was
 * taken away from it.
 */
export function detectOnlineMerchant(merchantRaw: string): OnlineCheckResult {
  if (!merchantRaw) return { isOnline: false };

  // TLD first: a payee carrying a real domain is unambiguous, and it
  // reports the more specific reason for "NETFLIX.COM"-style strings that
  // would also hit the brand list.
  const tldMatch = merchantRaw.match(TLD_RE);
  if (tldMatch) {
    return {
      isOnline: true,
      reason: 'tld_substring',
      matched: tldMatch[0],
    };
  }

  const brandMatch = merchantRaw.match(ONLINE_BRAND_RE);
  if (brandMatch) {
    return {
      isOnline: true,
      reason: 'online_brand',
      // Group 1 is the brand alone — the leading delimiter is excluded so
      // callers log "REDBUS", not "*REDBUS".
      matched: brandMatch[1],
    };
  }

  return { isOnline: false };
}
