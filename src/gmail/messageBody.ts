// Extract the readable text body and key headers from a Gmail message resource.
//
// Gmail returns messages with a tree of MIME parts; the text we want is in
// either a text/plain part, or (failing that) text/html which we strip to text.
// All bodies are base64url-encoded.

export interface GmailMessagePartHeader {
  name?: string | null;
  value?: string | null;
}

export interface GmailMessagePart {
  mimeType?: string | null;
  filename?: string | null;
  headers?: GmailMessagePartHeader[] | null;
  body?: { size?: number | null; data?: string | null } | null;
  parts?: GmailMessagePart[] | null;
}

export interface GmailMessageResource {
  id?: string | null;
  internalDate?: string | null; // ms since epoch as string
  payload?: GmailMessagePart | null;
  snippet?: string | null;
}

export interface ExtractedMessage {
  id: string;
  fromAddress: string | null;
  subject: string;
  snippet: string;
  body: string;
  receivedAt: Date;
}

export function extractMessage(msg: GmailMessageResource): ExtractedMessage {
  if (!msg.id) throw new Error('gmail message missing id');

  const payload = msg.payload ?? {};
  const headers = payload.headers ?? [];

  const subject = findHeader(headers, 'Subject') ?? '';
  const fromAddress = findHeader(headers, 'From');

  const text = findFirstTextBody(payload);

  // internalDate is ms-since-epoch as a string; fall back to now if absent
  const receivedAt = msg.internalDate
    ? new Date(Number(msg.internalDate))
    : new Date();

  return {
    id: msg.id,
    fromAddress: fromAddress ?? null,
    subject,
    snippet: msg.snippet ?? '',
    body: text,
    receivedAt,
  };
}

function findHeader(
  headers: GmailMessagePartHeader[],
  name: string,
): string | null {
  const target = name.toLowerCase();
  for (const h of headers) {
    if (h.name && h.name.toLowerCase() === target) return h.value ?? null;
  }
  return null;
}

// Walk the MIME tree: prefer text/plain; fall back to text/html (stripped).
export function findFirstTextBody(part: GmailMessagePart | null | undefined): string {
  if (!part) return '';

  const plain = collectPlainText(part);
  if (plain) return plain;

  const html = collectHtml(part);
  if (html) return stripHtml(html);

  return '';
}

function collectPlainText(part: GmailMessagePart): string | null {
  if (part.mimeType === 'text/plain' && part.body?.data) {
    return decodeBase64Url(part.body.data);
  }
  if (part.parts) {
    for (const child of part.parts) {
      const r = collectPlainText(child);
      if (r) return r;
    }
  }
  return null;
}

function collectHtml(part: GmailMessagePart): string | null {
  if (part.mimeType === 'text/html' && part.body?.data) {
    return decodeBase64Url(part.body.data);
  }
  if (part.parts) {
    for (const child of part.parts) {
      const r = collectHtml(child);
      if (r) return r;
    }
  }
  return null;
}

export function decodeBase64Url(s: string): string {
  // Gmail uses base64url variant: replace - and _ with + and /, pad with '='
  const normalized = s.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  return Buffer.from(padded, 'base64').toString('utf-8');
}

// Minimal HTML → text conversion: drop scripts/styles, collapse tags to spaces,
// decode the few entities we care about. Good enough for HDFC's templated HTML;
// not a general-purpose sanitizer.
export function stripHtml(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|tr|li|h[1-6])>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&rsquo;/g, "'")
    .replace(/&lsquo;/g, "'")
    .replace(/&rdquo;/g, '"')
    .replace(/&ldquo;/g, '"')
    .replace(/&#(\d+);/g, (_m, code: string) => String.fromCharCode(Number(code)))
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .replace(/[ \t]{2,}/g, ' ')
    .trim();
}

// Quick filter — used both at the routing layer and as a sanity check.
const HDFC_FROM_PATTERNS = [
  /alerts@hdfcbank\.net/i,
  /noreply\.alerts@hdfcbank\.net/i,
  /\bHDFC Bank\b/i,
];

// HDFC sends a steady stream of marketing emails from the SAME sender
// as transaction alerts ("Loan Limit Boosted to ₹7.5 Lacs",
// "Customer, get your dream car", "🎁 still haven't claimed your Rs.
// 800 voucher"). They look like alerts to the from-address filter,
// fail every transaction parser, and trigger our parser-miss push
// alert as if HDFC had changed a template. Subject-level blacklist
// short-circuits these as "not a transaction" before they ever hit
// the parser chain.
const MARKETING_SUBJECT_PATTERNS = [
  /\bloan\b/i,
  /\bsmart\s*emi\b/i,
  /\bemi loan\b/i,
  /\bvoucher\b/i,
  /\blimit boosted\b/i,
  /\bcongratulations\b/i,
  /\breward(s)?\b/i,
  /\bcashback\b/i,
  /\bdiscount\b/i,
  /\bdream car\b/i,
  /\bclaim(ed)?\s+(your|the)\b/i,
  /\bpre-?approved\b/i,
  /\bcredit\s+limit\s+(increase|boost)/i,
  /\boffer\b/i,
  /Update:\s/i, // "A/c xx5264 Update: ..." — HDFC's standard marketing prefix
];

export function isLikelyHdfcAlert(
  fromAddress: string | null,
  subject?: string | null,
): boolean {
  if (!fromAddress) return false;
  if (!HDFC_FROM_PATTERNS.some((re) => re.test(fromAddress))) return false;
  // Subject is the discriminator between real txn alerts and marketing.
  // If the caller didn't pass one, fall back to "looks like HDFC" — the
  // parser will still cleanly return no_template_match downstream.
  if (subject && MARKETING_SUBJECT_PATTERNS.some((re) => re.test(subject))) {
    return false;
  }
  return true;
}
