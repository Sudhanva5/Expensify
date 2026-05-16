// Online-merchant detector.
//
// Used at ingest time to decide whether to even *ask* iOS for the user's
// GPS for this transaction. For online charges (SaaS subs, domain
// renewals, card-on-file e-commerce), the iPhone's location is whatever
// random place the user was standing in when the merchant's webhook
// landed — and Places will dutifully return the nearest grocery store /
// café and confidently tag the transaction as that. We saw this happen
// in production: "NAME-CHEAP.COM* S0EXHV" got tagged as "Groceries /
// Vishal Mega Mart" because the user happened to be near a supermarket
// when their domain renewed.
//
// The fix is structural, not statistical: if the merchant is obviously
// online, skip the location pipeline entirely.

const ROUTING_PREFIX_RE =
  /^(RAZ|PAYU|CCD|BLLG|BBPS|STRIPE|PAYPAL|SQ|SQU|GPAY|GOOGLE\*?|PAYTM|MOBIK|PHONEPE|AMAZON|AMZN|FLIPK|BIG\s*BAZAR|NAME-CHEAP|GODADDY|NAMECHEAP|CLOUDFLR|VERCEL|RAILWAY|HEROKU|RENDER|FLY\.IO|AWS|GOOGLE\s*CLOUD|GCP|MICROSOFT|MSFT|APPLE\.COM|ITUNES|YOUTUBE|NETFLIX|SPOTIFY|HOTSTAR|DISNEY|ANTHROPIC|CLAUDE|OPENAI|CHATGPT|CURSOR|GITHUB|GITLAB|FIGMA|NOTION|VERCEL|LINEAR|SLACK|ZOOM|DROPBOX|GROW|GROWW|ZERODHA|SUBSTACK|PATREON|MEDIUM|TWITCH|DISCORD|TELEGRAM|ADOBE|MS365|M365|OFFICE\s*365|ICLOUD|GOOGLE\s*ONE|YT\s*PREMIUM|JIO\s*FIBER|AIRTEL\s*XSTREAM|TATA\s*PLAY|HOTSTAR|SONY\s*LIV|SONYLIV|ZEE5|VOOT|TIMES\s*PRIME|CRED\s*|UPSTOX|GROWW|ANGELONE|KUVERA|FYERS|FIDELITY|VANGUARD|COINBASE|BINANCE|WAZIR|WAZIRX|COIN\s*DCX|COINDCX|UDEMY|COURSERA|EDX|UNACADEMY|BYJU|VEDANTU|TIME\s*MAGAZINE|FT\.COM|WSJ|NYTIMES|ECONOMIST|BLOOMBERG|REUTERS|FORBES|SCROLL|THE\s*PRINT|THEPRINT|SQUARE\s*ENIX|EPIC\s*GAMES|EPICGAMES|STEAM|UBISOFT|PLAYSTATION|XBOX|NINTENDO|SWIGGY|BUNDL|ZOMATO|BLINKIT|INSTAMART|BIGBASKET|ZEPTO|DUNZO|BOOKMYSHOW|BMS|UBER|OLA|RAPIDO|REDBUS|REDB|MAKEMYTRIP|GOIBIBO|CLEARTRIP|EASEMYTRIP|IRCTC|INDIGO|AKASA|VISTARA|MYNTRA|MEESHO|JIOMART|FRESHTOHOME|LICIOUS|NYKAA|AJIO|TATA\s*CLIQ|TATACLIQ|FIRSTCRY|PHARM\s*EASY|PHARMEASY|APOLLO|MEDPLUS|NETMEDS|1MG|PRACTO|BEPANNAH|URBAN\s*COMPANY|URBANCOMPANY|TASKBOB|HOUSEJOY)[*\s\-_]/i;

// "domain.tld" appearing in the merchant string — strong tell for an online charge.
// We only match domain-looking patterns (something + dot + 2-5 letter TLD) to
// avoid false positives like "MR. SMITH".
const TLD_RE =
  /\b[a-z0-9-]{2,}\.(com|in|co|ai|app|io|net|org|me|tech|space|dev|cloud|store|live|tv|fm|gg)\b/i;

export interface OnlineCheckResult {
  isOnline: boolean;
  reason?: 'routing_prefix' | 'tld_substring';
  matched?: string;
}

/**
 * Decide whether a transaction's payee text indicates an online merchant.
 *
 * Heuristic — favours false negatives over false positives. A false negative
 * (online txn classified as physical) costs one stale location ping; a
 * false positive (physical txn classified as online) means we don't ask for
 * GPS for that row and miss the Places-resolution opportunity. We can
 * afford the former more than the latter.
 */
export function detectOnlineMerchant(merchantRaw: string): OnlineCheckResult {
  if (!merchantRaw) return { isOnline: false };

  const prefixMatch = merchantRaw.match(ROUTING_PREFIX_RE);
  if (prefixMatch) {
    return {
      isOnline: true,
      reason: 'routing_prefix',
      matched: prefixMatch[0],
    };
  }

  const tldMatch = merchantRaw.match(TLD_RE);
  if (tldMatch) {
    return {
      isOnline: true,
      reason: 'tld_substring',
      matched: tldMatch[0],
    };
  }

  return { isOnline: false };
}
