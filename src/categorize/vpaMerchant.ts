// Decode the originating merchant + payment gateway out of a UPI VPA.
//
// Sibling to vpaShape.ts: that file answers "is this a person or a business?",
// this one answers "which business, routed through whom?". Pure — no DB.
//
// The signal exists because payment aggregators mint per-merchant VPAs that
// embed both their own name and the merchant's:
//
//   netflixupi.payu@hdfcbank           Netflix,  via PayU
//   snitchapparelsp711507.rzp@rxaxis   Snitch,   via Razorpay
//   openaillc.cfp@cashfreensdlpb       OpenAI,   via Cashfree
//   lic.billdesk@hdfcbank              LIC,      via BillDesk
//
// UPI/NPCI carries no referrer, URL, or domain — there is no such field on
// the rail and none in the HDFC email. "Which site" is therefore recoverable
// only as far as the merchant's registered name, never as an actual address.
//
// Two hard rules:
//   1. Never decode a personal VPA. Renaming a human after a gateway
//      heuristic is the one unacceptable failure here, so the whole function
//      is gated behind classifyVpa().
//   2. Never guess. Opaque merchant ids (paytm.d15687920262, q385969427)
//      return a gateway and a null merchant rather than an invented name.

import { classifyVpa } from './vpaShape.js';

export interface DecodedVpa {
  /// Cleaned, display-ready merchant name, or null when the local part is an
  /// opaque id that carries no name.
  merchant: string | null;
  /// Payment aggregator that minted the VPA, or null when no known token is
  /// present.
  gateway: string | null;
}

/// Gateway tokens as they appear inside the VPA local part, mapped to the
/// name we show the user. Keys are matched against dot/dash/underscore
/// separated segments, so a merchant literally named "atom" can't collide.
const GATEWAY_TOKENS: Record<string, string> = {
  rzp: 'Razorpay',
  razorpay: 'Razorpay',
  payu: 'PayU',
  cfp: 'Cashfree',
  cf: 'Cashfree',
  cashfree: 'Cashfree',
  hyperpg: 'Juspay',
  juspay: 'Juspay',
  billdesk: 'BillDesk',
  ccav: 'CCAvenue',
  ccavenue: 'CCAvenue',
  easebuzz: 'Easebuzz',
  instamojo: 'Instamojo',
  pinelabs: 'Pine Labs',
  worldline: 'Worldline',
  paytm: 'Paytm',
  // Not an aggregator — the BharatQR interoperable QR standard. Still worth
  // surfacing as the rail the payment took.
  bqr: 'BharatQR',
};

/// Rail markers that are neither the merchant nor the aggregator. Dropped
/// from the merchant slug without setting a gateway, so "redbus.dbqr.payu"
/// reads as redBus via PayU rather than "Redbusdbqr".
const SEGMENT_NOISE = new Set(['dbqr', 'qr', 'pg', 'merchant', 'in']);

/// Handles that identify the aggregator even when the local part doesn't.
const GATEWAY_HANDLES: Record<string, string> = {
  pty: 'Paytm',
  ptys: 'Paytm',
  ptybl: 'Paytm',
  razorpay: 'Razorpay',
  payu: 'PayU',
  instamojo: 'Instamojo',
  ccavenue: 'CCAvenue',
};

/// Corporate / rail noise stripped off the end of a merchant slug, longest
/// first so `privatelimited` wins over `limited`.
const NOISE_SUFFIXES = [
  'privatelimited',
  'marketplace',
  'technologies',
  'technology',
  'enterprises',
  'enterprise',
  'solutions',
  'solution',
  'apparels',
  'apparel',
  'payments',
  'payment',
  'services',
  'service',
  'private',
  'limited',
  'privat',
  'online',
  'retail',
  'india',
  'pvtltd',
  'store',
  'ltd',
  'llc',
  'inc',
  'upi',
  'ind',
  'com',
  'pvt',
].sort((a, b) => b.length - a.length);

/// Names that title-casing would mangle. Keyed on the cleaned slug.
const CANONICAL_NAMES: Record<string, string> = {
  openai: 'OpenAI',
  lic: 'LIC',
  hdfc: 'HDFC',
  icici: 'ICICI',
  sbi: 'SBI',
  bsnl: 'BSNL',
  ola: 'Ola',
  bookmyshow: 'BookMyShow',
  makemytrip: 'MakeMyTrip',
  redbus: 'redBus',
  // District (Zomato's events/movies arm) mints one VPA per product line;
  // both should read as the one brand the user recognises.
  districtmovies: 'District',
  districtmovieticket: 'District',
};

/**
 * Decode a VPA into its merchant + gateway. Returns null when the VPA is
 * personal, malformed, or carries no recoverable signal at all.
 */
export function decodeVpaMerchant(vpa: string): DecodedVpa | null {
  const trimmed = vpa.trim().toLowerCase();
  if (!trimmed.includes('@')) return null;

  const atIdx = trimmed.lastIndexOf('@');
  const local = trimmed.slice(0, atIdx);
  const handle = trimmed.slice(atIdx + 1);
  if (!local || !handle) return null;

  // Rule 1: never touch a person.
  if (classifyVpa(trimmed) === 'personal') return null;

  const segments = local.split(/[.\-_]+/).filter(Boolean);
  if (segments.length === 0) return null;

  // Find the gateway token, and keep the remaining segments as the merchant
  // candidate. A gateway token in any position is removed.
  let gateway: string | null = null;
  const remaining: string[] = [];
  for (const seg of segments) {
    const hit = GATEWAY_TOKENS[seg];
    if (hit && gateway === null) {
      gateway = hit;
      continue;
    }
    if (SEGMENT_NOISE.has(seg)) continue;
    remaining.push(seg);
  }
  gateway ??= GATEWAY_HANDLES[handle] ?? null;

  // No gateway anywhere means this isn't an aggregator-minted VPA. Bail
  // rather than start renaming ordinary merchant VPAs off their local part.
  if (gateway === null) return null;

  const merchant = cleanMerchantSlug(remaining.join(''));
  if (merchant === null) return { merchant: null, gateway };
  return { merchant, gateway };
}

/**
 * Turn the leftover local-part segments into a display name, or null when
 * what's left is an opaque id rather than a name.
 */
function cleanMerchantSlug(raw: string): string | null {
  // Strip trailing digit runs: the per-outlet counter aggregators append
  // (redbus32, airbnbpaymentsind1, snitchapparelsp711507).
  let slug = raw.replace(/\d+$/, '');
  slug = stripNoiseSuffixes(slug);

  if (slug.length < 3) return null;
  // Anything still carrying digits, or that reads as a hex/id blob, is an
  // opaque merchant reference. Refuse rather than invent.
  if (/\d/.test(slug)) return null;

  return CANONICAL_NAMES[slug] ?? slug.charAt(0).toUpperCase() + slug.slice(1);
}

/**
 * Repeatedly peel known corporate noise off the end.
 *
 * The single-character retry handles aggregator slugs that got truncated
 * mid-word before the counter ("snitchapparelsp", "ctrlxtechnologiesp").
 * It only commits the dropped character when doing so actually exposes a
 * real suffix, so it can't chew into a legitimate name.
 */
function stripNoiseSuffixes(input: string): string {
  let slug = input;

  for (;;) {
    const direct = NOISE_SUFFIXES.find(
      (s) => slug.endsWith(s) && slug.length > s.length + 2,
    );
    if (direct) {
      slug = slug.slice(0, -direct.length);
      continue;
    }

    // Speculative one-char drop — only kept if it unlocks a suffix.
    const trimmedOne = slug.slice(0, -1);
    const unlocked = NOISE_SUFFIXES.find(
      (s) => trimmedOne.endsWith(s) && trimmedOne.length > s.length + 2,
    );
    if (unlocked) {
      slug = trimmedOne.slice(0, -unlocked.length);
      continue;
    }

    return slug;
  }
}

/**
 * Is `merchantRaw` just a copy of the VPA rather than a real trading name?
 *
 * This is the gate on using the decoded name for display. HDFC often sends a
 * perfectly good name ("NETFLIX COM", "Tacobell Nexus Mall") and we must not
 * override it — but just as often it echoes the VPA back at us
 * ("districtmovies.payu", "snitchapparelsp711507.rzp"), and that's the case
 * the decode exists to fix.
 */
export function isMerchantRawAnEchoOfVpa(
  merchantRaw: string,
  vpa: string,
): boolean {
  const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, '');
  const raw = norm(merchantRaw);
  if (!raw) return true;

  const full = norm(vpa);
  const localPart = norm(vpa.split('@')[0] ?? '');

  return raw === full || raw === localPart;
}
