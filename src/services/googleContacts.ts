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

  // Name fallback. We pull every contact with a photo and try two
  // matching strategies in order:
  //
  //   1. COMPACT-FORM MATCH — strip non-letters from both sides and
  //      check substring containment. This is what catches the VPA
  //      `sagarprabhu251-1@okhdfcbank` against contact "Sagar Prabhu":
  //      compact local "sagarprabhu" == compact name "sagarprabhu".
  //      Token-overlap scoring (the previous-only strategy) misses
  //      this because "sagar prabhu" with its space doesn't .includes
  //      the runtogether "sagarprabhu".
  //
  //   2. TOKEN-OVERLAP — for VPAs where the local-part legitimately
  //      contains separators (`sneha.r@oksbi`), score by how many
  //      tokens overlap. Requires ≥2 hits to avoid matching every
  //      "Kumar" in the address book.
  const haystack = await prisma.googleContact.findMany({
    where: { photoUrl: { not: null } },
    select: { resourceName: true, displayName: true, photoUrl: true, givenName: true, familyName: true },
  });
  if (haystack.length === 0) return null;

  const queryCompact = compactizeLocal(opts.vpa, opts.merchantRaw);

  // Strategy 1: compact-form substring match. Uniqueness guarded — a
  // single common compact like "kumar" could match dozens of contacts;
  // in that case fall through to token-overlap which has explicit
  // scoring. Only return on exact-one compact-form hit.
  if (queryCompact && queryCompact.length >= 6) {
    const compactHits: typeof haystack = [];
    for (const c of haystack) {
      const candidateCompact = compactizeName(c);
      if (!candidateCompact || candidateCompact.length < 4) continue;
      if (
        candidateCompact.includes(queryCompact) ||
        queryCompact.includes(candidateCompact)
      ) {
        compactHits.push(c);
      }
    }
    if (compactHits.length === 1) {
      const c = compactHits[0]!;
      return {
        resourceName: c.resourceName,
        displayName: c.displayName,
        photoUrl: c.photoUrl,
        matchedOn: 'name',
      };
    }
  }

  // Strategy 2: token-overlap fallback for separator-bearing locals.
  const tokens = tokensFor(opts.vpa, opts.merchantRaw);
  if (tokens.size === 0) return null;

  let bestScore = 0;
  let best: ContactLookupResult | null = null;
  for (const c of haystack) {
    const candidate = [c.displayName, c.givenName, c.familyName]
      .filter((s): s is string => !!s)
      .join(' ')
      .toLowerCase();
    if (!candidate) continue;
    let score = 0;
    for (const t of tokens) {
      if (candidate.includes(t)) score++;
    }
    if (score > bestScore) {
      bestScore = score;
      best = {
        resourceName: c.resourceName,
        displayName: c.displayName,
        photoUrl: c.photoUrl,
        matchedOn: 'name',
      };
    }
  }
  if (bestScore < 2) return null;
  return best;
}

/** Strip everything that isn't a letter, lowercase. "Sagar Prabhu" → "sagarprabhu". */
function compactizeName(c: {
  displayName: string | null;
  givenName: string | null;
  familyName: string | null;
}): string {
  const joined = [c.displayName, c.givenName, c.familyName]
    .filter((s): s is string => !!s)
    .join('');
  return joined.toLowerCase().replace(/[^a-z]+/g, '');
}

/** Same idea for the query side — drop @handle and any digits/punct. */
function compactizeLocal(vpa: string | null, merchantRaw: string | null | undefined): string {
  const parts: string[] = [];
  if (vpa) {
    const local = vpa.split('@')[0] ?? '';
    parts.push(local);
  }
  if (merchantRaw) parts.push(merchantRaw);
  return parts.join('').toLowerCase().replace(/[^a-z]+/g, '');
}

function tokensFor(vpa: string | null, merchantRaw: string | null | undefined): Set<string> {
  const out = new Set<string>();
  if (merchantRaw) {
    for (const t of merchantRaw.toLowerCase().split(/[^a-z]+/)) {
      if (t.length >= 3) out.add(t);
    }
  }
  if (vpa) {
    const local = vpa.split('@')[0] ?? '';
    for (const t of local.toLowerCase().split(/[^a-z]+/)) {
      if (t.length >= 3) out.add(t);
    }
  }
  return out;
}
