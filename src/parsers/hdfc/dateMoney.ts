// Helpers for parsing money and HDFC's three different date formats.
// All HDFC times are assumed to be IST (no explicit timezone in the emails).

const IST_OFFSET_MS = (5 * 60 + 30) * 60 * 1000;

const MONTHS: Record<string, number> = {
  Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5,
  Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11,
};

/// Case-insensitive month lookup — "JUN", "Jun", and "jun" all resolve.
/// Returns null on unknown month rather than throwing, so callers can
/// emit better error messages.
function findMonth(s: string): number | null {
  if (s.length !== 3) return null;
  const cap = s.charAt(0).toUpperCase() + s.slice(1, 3).toLowerCase();
  const m = MONTHS[cap];
  return m === undefined ? null : m;
}

// "5,000.00" → 500000n (paise / cents — caller knows the currency)
// "94"       → 9400n
// "94.5"     → 9450n
export function parseMinorUnits(raw: string): bigint {
  const cleaned = raw.replace(/,/g, '').trim();
  const [whole, frac = '00'] = cleaned.split('.');
  if (!whole) throw new Error(`bad amount: ${raw}`);
  const fracPadded = (frac + '00').slice(0, 2);
  return BigInt(whole) * 100n + BigInt(fracPadded);
}

// "10-05-26" (DD-MM-YY) → Date in UTC representing IST clock time.
// If the email body has no time-of-day, fall back to the receivedAt time.
export function parseDdMmYy(s: string, receivedAt: Date): Date {
  const m = /^(\d{2})-(\d{2})-(\d{2})$/.exec(s);
  if (!m) throw new Error(`bad date (DD-MM-YY): ${s}`);
  const d = Number(m[1]);
  const mo = Number(m[2]);
  const yy = Number(m[3]);
  return istClockToUtc(2000 + yy, mo - 1, d, receivedAt);
}

// "05/05/2026" (DD/MM/YYYY)
export function parseDdMmYyyy(s: string, receivedAt: Date): Date {
  const m = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(s);
  if (!m) throw new Error(`bad date (DD/MM/YYYY): ${s}`);
  return istClockToUtc(Number(m[3]), Number(m[2]) - 1, Number(m[1]), receivedAt);
}

// "17-JUN-26" (DD-MMM-YY, uppercase 3-letter month, 2-digit year). Used
// by the HDFC balance update email ("as of 17-JUN-26"). Inherits the
// hh:mm:ss from receivedAt — the email reports a calendar date with no
// time component, but we want the row's `asOf` to sort correctly
// alongside transaction occurredAt values that DO carry time.
export function parseDdMmmYy(s: string, receivedAt: Date): Date {
  const m = /^(\d{1,2})-([A-Za-z]{3})-(\d{2})$/.exec(s.trim());
  if (!m) throw new Error(`bad date (DD-MMM-YY): ${s}`);
  const month = findMonth(m[2]!);
  if (month === null) throw new Error(`bad month: ${m[2]}`);
  return istClockToUtc(2000 + Number(m[3]), month, Number(m[1]), receivedAt);
}

// "17-06-2026 21:12:59" (DD-MM-YYYY HH:MM:SS, hyphen-separated date).
// Used by the cc_thanks template ("Thank you for using your HDFC Bank
// Credit Card ending in ..."). Combined date+time string so a single
// parser is simpler than two regex captures + two-arg call site.
export function parseDdMmYyyyHms(s: string): Date {
  const m =
    /^(\d{2})-(\d{2})-(\d{4})\s+(\d{2}):(\d{2}):(\d{2})$/.exec(s.trim());
  if (!m) throw new Error(`bad date (DD-MM-YYYY HH:MM:SS): ${s}`);
  return zonedToUtc(
    Number(m[3]),
    Number(m[2]) - 1,
    Number(m[1]),
    Number(m[4]),
    Number(m[5]),
    Number(m[6]),
  );
}

// "17 May, 2026" (no time). Inherits hh:mm:ss from receivedAt like
// parseDdMmYy does. Used by the new (May 2026) HDFC CC-UPI debit
// template which dropped the explicit time field.
export function parseDdMonYyyy(s: string, receivedAt: Date): Date {
  const m = /^(\d{1,2})\s+(\w{3}),?\s+(\d{4})$/.exec(s.trim());
  if (!m) throw new Error(`bad date (DD Mon YYYY): ${s}`);
  const month = MONTHS[m[2] as keyof typeof MONTHS];
  if (month === undefined) throw new Error(`bad month: ${m[2]}`);
  return istClockToUtc(Number(m[3]), month, Number(m[1]), receivedAt);
}

// "09 May, 2026" + "10:57:54" → IST clock-time as UTC Date
export function parseDdMonYyyyHms(dateStr: string, timeStr: string): Date {
  const dm = /^(\d{1,2})\s+(\w{3}),\s+(\d{4})$/.exec(dateStr);
  if (!dm) throw new Error(`bad date (DD Mon, YYYY): ${dateStr}`);
  const month = MONTHS[dm[2] as keyof typeof MONTHS];
  if (month === undefined) throw new Error(`bad month: ${dm[2]}`);

  const tm = /^(\d{2}):(\d{2}):(\d{2})$/.exec(timeStr);
  if (!tm) throw new Error(`bad time: ${timeStr}`);

  return zonedToUtc(
    Number(dm[3]),
    month,
    Number(dm[1]),
    Number(tm[1]),
    Number(tm[2]),
    Number(tm[3]),
  );
}

// Build a Date that represents an IST clock-time. JS Date is internally UTC,
// so we subtract the IST offset from the UTC-built timestamp.
function zonedToUtc(
  y: number, m: number, d: number,
  hh: number, mm: number, ss: number,
): Date {
  return new Date(Date.UTC(y, m, d, hh, mm, ss) - IST_OFFSET_MS);
}

// When email has only a date (no time), inherit hh:mm:ss from receivedAt
// (interpreted as IST). This keeps "today" grouping correct in IST.
function istClockToUtc(y: number, m: number, d: number, receivedAt: Date): Date {
  const istReceived = new Date(receivedAt.getTime() + IST_OFFSET_MS);
  const hh = istReceived.getUTCHours();
  const mm = istReceived.getUTCMinutes();
  const ss = istReceived.getUTCSeconds();
  return zonedToUtc(y, m, d, hh, mm, ss);
}
