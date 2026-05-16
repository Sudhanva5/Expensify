// Google People API client. Fetches the authenticated user's contacts so
// the backend can attach a "who am I paying" photo to UPI rows where the
// VPA's local part is a phone number that matches a contact.
//
// Why on the backend rather than entirely on iOS:
//   - The iOS CNContactStore covers contacts saved in the device address
//     book, but many people leave contacts only in Google (the device
//     book never syncs them). The bank statement payee says "RAJESH
//     KUMAR" — a useless name — while the Google contact entry has
//     "Rajesh — Plumber", his correct photo, and the phone number that
//     matches the UPI VPA "9876543210@ybl".
//   - Centralizing on the backend lets us cache photos once and reuse
//     across devices later (V2 multi-user).
//
// The flow:
//   1. `syncGoogleContacts()` pulls the user's connections via People API,
//      normalizes phone numbers, persists to `GoogleContact`.
//   2. `lookupByVpa(vpa)` extracts a phone-shaped prefix from a VPA and
//      searches the cached table for a match.
//   3. iOS hits `GET /contacts/google-lookup` with a VPA and falls back
//      to the returned photo URL when its local match has none.

import { google } from 'googleapis';
import type { OAuth2Client } from 'google-auth-library';
import { prisma } from '../db/client.js';
import { classifyVpa } from '../categorize/vpaShape.js';

/** Reduce a phone string to digits only (drops +91, spaces, dashes). */
export function normalizePhone(raw: string): string {
  return raw.replace(/\D+/g, '');
}

/**
 * Extract a phone-number candidate from a UPI VPA. UPI handles like
 *   `9876543210@ybl`, `+91-9876543210@paytm`, `91987654 3210@ibl`
 * all share a digits-only stem; we treat the LAST 10 digits as the
 * matching key (Indian mobile numbers, no country code).
 *
 * Returns null when the local part isn't phone-shaped (e.g.
 * `rajesh.kumar@oksbi`, `q1234@ybl`).
 */
export function extractPhoneFromVpa(vpa: string): string | null {
  const local = vpa.split('@')[0] ?? '';
  const digits = local.replace(/\D+/g, '');
  if (digits.length < 10) return null;
  return digits.slice(-10);
}

interface PeopleApiPhone {
  value?: string | null;
  canonicalForm?: string | null;
}
interface PeopleApiName {
  displayName?: string | null;
  givenName?: string | null;
  familyName?: string | null;
}
interface PeopleApiEmail {
  value?: string | null;
}
interface PeopleApiPhoto {
  url?: string | null;
  default?: boolean | null;
}
interface PeopleApiPerson {
  resourceName?: string | null;
  names?: PeopleApiName[] | null;
  phoneNumbers?: PeopleApiPhone[] | null;
  emailAddresses?: PeopleApiEmail[] | null;
  photos?: PeopleApiPhoto[] | null;
}

/**
 * Walk the People API pagination, return every connection with the
 * fields we care about. Limited to the authenticated user's own
 * contacts ("people/me/connections"); does not touch directory APIs
 * (which require Workspace setup).
 */
export async function fetchAllContacts(
  auth: OAuth2Client,
): Promise<PeopleApiPerson[]> {
  const people = google.people({ version: 'v1', auth });
  const all: PeopleApiPerson[] = [];
  let pageToken: string | undefined;
  do {
    const res = await people.people.connections.list({
      resourceName: 'people/me',
      personFields: 'names,phoneNumbers,emailAddresses,photos',
      pageSize: 1000,
      ...(pageToken !== undefined ? { pageToken } : {}),
    });
    for (const p of res.data.connections ?? []) {
      all.push(p);
    }
    pageToken = res.data.nextPageToken ?? undefined;
  } while (pageToken);
  return all;
}

/**
 * Pull the latest contacts from Google and overwrite the cache. Single-
 * user V1; multi-user would key by GmailOauth row id. A re-sync wipes
 * stale entries (deleted-in-Google contacts), so we don't accumulate
 * ghosts.
 */
export async function syncGoogleContacts(
  auth: OAuth2Client,
): Promise<{ fetched: number; saved: number }> {
  const people = await fetchAllContacts(auth);

  // Skip "default photo" entries (Google returns a fallback avatar URL
  // for contacts with no photo set; we'd rather show no photo at all
  // than a generic silhouette).
  const rows = people
    .map((p) => {
      const resourceName = p.resourceName ?? '';
      if (!resourceName) return null;
      const name = p.names?.[0];
      const phonesRaw =
        p.phoneNumbers?.map((ph) => ph.canonicalForm || ph.value || '')
          .filter((s) => s.length > 0) ?? [];
      const phoneDigits = phonesRaw.map(normalizePhone).filter((d) => d.length >= 10);
      const emails = p.emailAddresses?.map((e) => e.value || '').filter((s) => s.length > 0) ?? [];
      const realPhoto = p.photos?.find((ph) => ph.default !== true && !!ph.url);
      return {
        resourceName,
        displayName: name?.displayName ?? null,
        givenName: name?.givenName ?? null,
        familyName: name?.familyName ?? null,
        phonesRaw,
        phoneDigits,
        emails,
        photoUrl: realPhoto?.url ?? null,
      };
    })
    .filter((r): r is NonNullable<typeof r> => r !== null);

  // Atomic-ish swap: clear + re-insert in a transaction. Cheap given
  // contact lists are O(hundreds), not O(thousands).
  await prisma.$transaction(async (tx) => {
    await tx.googleContact.deleteMany({});
    if (rows.length > 0) {
      await tx.googleContact.createMany({ data: rows });
    }
  });

  return { fetched: people.length, saved: rows.length };
}

export interface ContactLookupResult {
  resourceName: string;
  displayName: string | null;
  photoUrl: string | null;
  matchedOn: 'phone' | 'name';
}

/**
 * Look up a contact by VPA (phone-shaped local part) and/or a raw
 * merchant string. Phone match wins; name match is a softer fallback
 * for VPAs like `rajesh.kumar@oksbi`.
 */
export async function lookupByVpa(opts: {
  vpa: string | null;
  merchantRaw?: string | null;
}): Promise<ContactLookupResult | null> {
  // Merchant VPAs (q\d+@ybl, paytmqr*, ok*biz handles) belong to shops,
  // not people. Refuse to attach a contact identity to them, even if
  // the merchant text or a stored contact name shares letters with the
  // VPA local-part. This is the backend mirror of the iOS-side guard.
  if (opts.vpa && classifyVpa(opts.vpa) === 'merchant') {
    return null;
  }

  if (opts.vpa) {
    const phoneKey = extractPhoneFromVpa(opts.vpa);
    if (phoneKey) {
      const hit = await prisma.googleContact.findFirst({
        where: { phoneDigits: { has: phoneKey } },
        select: { resourceName: true, displayName: true, photoUrl: true },
      });
      if (hit) return { ...hit, matchedOn: 'phone' };
    }
  }

  // Name fallback — STRICT TOKEN OVERLAP.
  //
  // Rule: every meaningful token in the bank's payee text must appear
  // in the contact's name. VPA-local tokens are tiebreakers only,
  // never enough on their own to claim a contact.
  //
  // Pre-fix bug:
  //   "SNEHA R" + vpa s.neha2003rajesh@okhdfcbank → contact "Rajesh"
  //   was returned because "rajesh" appeared in the VPA-local compact.
  //   Now: "Rajesh" lacks the merchant-text token "sneha" → rejected.
  //   "Sneha Babluu" (or any other "Sneha …") wins.
  //
  // Mirrors ContactsService.match(for:) on iOS so both surfaces give
  // identical answers.
  const haystack = await prisma.googleContact.findMany({
    where: { photoUrl: { not: null } },
    select: { resourceName: true, displayName: true, photoUrl: true, givenName: true, familyName: true },
  });
  if (haystack.length === 0) return null;

  const merchantTokens = tokenize(opts.merchantRaw ?? '');
  if (merchantTokens.size === 0) return null;
  const vpaTokens = opts.vpa
    ? tokenize(opts.vpa.split('@')[0] ?? '')
    : new Set<string>();
  // Drop overlap so VPA tokens don't double-count merchant tokens.
  for (const t of merchantTokens) vpaTokens.delete(t);

  let bestScore = -1;
  let topCandidates: Array<(typeof haystack)[number]> = [];
  for (const c of haystack) {
    const contactTokens = tokenize(
      [c.displayName, c.givenName, c.familyName]
        .filter((s): s is string => !!s)
        .join(' '),
    );
    let merchantOverlap = 0;
    for (const t of merchantTokens) if (contactTokens.has(t)) merchantOverlap++;
    if (merchantOverlap < merchantTokens.size) continue; // strict gate
    let vpaOverlap = 0;
    for (const t of vpaTokens) if (contactTokens.has(t)) vpaOverlap++;
    const score = merchantOverlap * 10 + vpaOverlap;
    if (score > bestScore) {
      bestScore = score;
      topCandidates = [c];
    } else if (score === bestScore) {
      topCandidates.push(c);
    }
  }
  if (topCandidates.length !== 1) return null;
  const winner = topCandidates[0]!;
  return {
    resourceName: winner.resourceName,
    displayName: winner.displayName,
    photoUrl: winner.photoUrl,
    matchedOn: 'name',
  };
}

/** Lowercase + split on non-letters, keep words ≥ 2 letters. */
function tokenize(s: string): Set<string> {
  const out = new Set<string>();
  for (const t of s.toLowerCase().split(/[^a-z]+/)) {
    if (t.length >= 2) out.add(t);
  }
  return out;
}
