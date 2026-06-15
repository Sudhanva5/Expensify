// Small helpers shared by every MCP tool. Two things matter:
//   1. BigInt safety — Transaction.amountInrMinor is BigInt. JSON.stringify
//      explodes on it; LLMs reason badly about it; so we surface paise as
//      Number rupees in tool output.
//   2. IST date math — everything in the app is IST. Tool args take
//      YYYY-MM-DD / YYYY-MM and we expand them against UTC+5:30 explicitly
//      so a "2026-06" query catches June-in-IST, not "first 23.5h of June UTC".

const IST_OFFSET_MS = 5.5 * 60 * 60 * 1000;

/// Wraps an arbitrary payload as the single text-content block an MCP
/// tool returns. Stringifies BigInt as a decimal string so nothing
/// downstream explodes. Pretty-prints for human readability — these
/// payloads are about to be reasoned over by an LLM, and prettified
/// JSON tokenizes more legibly than minified.
export function asJsonText(payload: unknown): {
  type: 'text';
  text: string;
} {
  return {
    type: 'text',
    text: JSON.stringify(payload, bigIntReplacer, 2),
  };
}

function bigIntReplacer(_key: string, value: unknown): unknown {
  if (typeof value === 'bigint') return value.toString();
  return value;
}

/// Convert paise (minor units, BigInt) to rupees (Number). Lossy for
/// values above 2^53 but every personal-expense row is comfortably
/// inside that range.
export function minorToInr(minor: bigint | null | undefined): number | null {
  if (minor === null || minor === undefined) return null;
  return Number(minor) / 100;
}

/// Convert rupees (Number) to paise (BigInt). Used to translate
/// LLM-supplied filter bounds (e.g. minAmountInr) into the column type.
export function inrToMinor(rupees: number): bigint {
  return BigInt(Math.round(rupees * 100));
}

/// Start of an IST day expressed as a UTC Date instant.
/// "2026-06-15" → 2026-06-14T18:30:00.000Z (which is 2026-06-15T00:00 IST).
export function startOfIstDay(iso: string): Date {
  const parts = parseYmd(iso);
  const utcMidnight = Date.UTC(parts.year, parts.month - 1, parts.day);
  return new Date(utcMidnight - IST_OFFSET_MS);
}

/// End of an IST day expressed as a UTC Date instant (exclusive next-day
/// boundary, suitable for `lt` queries).
export function endOfIstDay(iso: string): Date {
  const parts = parseYmd(iso);
  const utcNext = Date.UTC(parts.year, parts.month - 1, parts.day + 1);
  return new Date(utcNext - IST_OFFSET_MS);
}

/// IST-bound range for a "YYYY-MM" string. `start` is the first instant
/// of that month in IST, `end` is the first instant of the next month
/// (exclusive — use `lt: end` in Prisma).
export function monthBounds(yearMonth: string): { start: Date; end: Date } {
  const m = /^(\d{4})-(\d{2})$/.exec(yearMonth);
  if (!m) {
    throw new Error(`Invalid month "${yearMonth}", expected YYYY-MM`);
  }
  const year = Number(m[1]);
  const month = Number(m[2]);
  const startUtc = Date.UTC(year, month - 1, 1);
  const endUtc = Date.UTC(year, month, 1);
  return {
    start: new Date(startUtc - IST_OFFSET_MS),
    end: new Date(endUtc - IST_OFFSET_MS),
  };
}

/// Current IST month as "YYYY-MM". Used as a default for tools that
/// take an optional `yearMonth` arg.
export function currentMonthIst(): string {
  const istNow = new Date(Date.now() + IST_OFFSET_MS);
  const y = istNow.getUTCFullYear();
  const m = String(istNow.getUTCMonth() + 1).padStart(2, '0');
  return `${y}-${m}`;
}

function parseYmd(iso: string): { year: number; month: number; day: number } {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) {
    throw new Error(`Invalid date "${iso}", expected YYYY-MM-DD`);
  }
  return {
    year: Number(m[1]),
    month: Number(m[2]),
    day: Number(m[3]),
  };
}
