// Rule-engine evaluator: returns true if a transaction matches all conditions
// in a rule. All time/day comparisons use IST.

import type { ParsedTransaction } from '../parsers/hdfc/index.js';
import type {
  UserRule,
  RuleConditions,
  RuleEvalContext,
  DayOfWeek,
} from './types.js';
import { DAYS_OF_WEEK } from './types.js';

const IST_OFFSET_MS = (5 * 60 + 30) * 60 * 1000;

export function evaluateRule(
  rule: UserRule,
  tx: ParsedTransaction,
  ctx: RuleEvalContext,
): boolean {
  if (!rule.enabled) return false;
  return evaluateConditions(rule.conditions, tx, ctx);
}

export function evaluateConditions(
  c: RuleConditions,
  tx: ParsedTransaction,
  ctx: RuleEvalContext,
): boolean {
  if (c.direction !== undefined && c.direction !== tx.direction) return false;

  if (c.instrument !== undefined) {
    const allowed = Array.isArray(c.instrument) ? c.instrument : [c.instrument];
    if (!allowed.includes(tx.instrument)) return false;
  }

  if (c.amountBetween !== undefined) {
    const [lo, hi] = c.amountBetween;
    const major = Number(tx.amountMinor) / 100;
    if (major < lo || major > hi) return false;
  }

  if (c.timeOfDayBetween !== undefined) {
    const istMins = istMinutesOfDay(tx.occurredAt);
    if (!withinTimeRange(istMins, c.timeOfDayBetween)) return false;
  }

  if (c.dayOfWeek !== undefined) {
    const day = istDayOfWeek(tx.occurredAt);
    if (!c.dayOfWeek.includes(day)) return false;
  }

  if (c.payeeContains !== undefined) {
    if (!tx.merchantRaw.toLowerCase().includes(c.payeeContains.toLowerCase())) {
      return false;
    }
  }

  if (c.payeeRegex !== undefined) {
    if (!new RegExp(c.payeeRegex, 'i').test(tx.merchantRaw)) return false;
  }

  if (c.payeeNotInAliasTable === true && ctx.aliasMatched) return false;

  if (c.vpaShape !== undefined && ctx.vpaShape !== c.vpaShape) return false;

  if (c.locationWithinRadius !== undefined) {
    // No GPS available → can't evaluate, treat as non-match (caller
    // will re-run rules later when location uploads).
    if (ctx.txLat === undefined || ctx.txLng === undefined) return false;
    const d = haversineMeters(
      ctx.txLat,
      ctx.txLng,
      c.locationWithinRadius.lat,
      c.locationWithinRadius.lng,
    );
    if (d > c.locationWithinRadius.meters) return false;
  }

  return true;
}

/**
 * Great-circle distance between two lat/lng points, in metres. Same
 * formula used by `recategorizeWithLocation`; duplicated here to keep
 * rules.ts self-contained.
 */
function haversineMeters(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number,
): number {
  const R = 6_371_000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function istMinutesOfDay(d: Date): number {
  const ist = new Date(d.getTime() + IST_OFFSET_MS);
  return ist.getUTCHours() * 60 + ist.getUTCMinutes();
}

function istDayOfWeek(d: Date): DayOfWeek {
  const ist = new Date(d.getTime() + IST_OFFSET_MS);
  // JS: 0=Sun..6=Sat. We index DAYS_OF_WEEK with Mon=0..Sun=6.
  const day = DAYS_OF_WEEK[(ist.getUTCDay() + 6) % 7];
  if (!day) throw new Error('unreachable');
  return day;
}

function withinTimeRange(curMins: number, range: [string, string]): boolean {
  const start = parseHM(range[0]);
  const end = parseHM(range[1]);
  if (start <= end) return curMins >= start && curMins <= end;
  // Wraps midnight (e.g., 22:00–06:00)
  return curMins >= start || curMins <= end;
}

function parseHM(s: string): number {
  const m = /^(\d{1,2}):(\d{2})$/.exec(s);
  if (!m) throw new Error(`bad time: ${s}`);
  return Number(m[1]) * 60 + Number(m[2]);
}
