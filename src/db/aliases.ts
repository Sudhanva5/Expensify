// Repository: load merchant aliases and autopay aliases from DB.
// Returns plain in-memory shapes that categorize() expects — keeps the
// orchestrator decoupled from Prisma row types.

import { prisma } from './client.js';
import type {
  AliasEntry,
  AliasMatchType,
  AutopayAliasEntry,
  CategoryName,
} from '../categorize/types.js';
import { CATEGORIES } from '../categorize/types.js';

const VALID_CATEGORY_SET = new Set<string>(CATEGORIES);

function asCategoryName(name: string | null | undefined): CategoryName | null {
  if (!name) return null;
  return VALID_CATEGORY_SET.has(name) ? (name as CategoryName) : null;
}

function asMatchType(s: string): AliasMatchType {
  if (s === 'exact' || s === 'substring' || s === 'regex') return s;
  throw new Error(`unknown matchType in DB: ${s}`);
}

export async function listMerchantAliases(): Promise<AliasEntry[]> {
  const rows = await prisma.merchantAlias.findMany({
    where: { OR: [{ notes: null }, { NOT: { notes: 'autopay' } }] },
    include: { category: true },
  });
  return rows.map((r) => ({
    pattern: r.rawPattern,
    matchType: asMatchType(r.matchType),
    canonical: r.canonical,
    category: asCategoryName(r.category?.name),
    ...(r.notes ? { notes: r.notes } : {}),
  }));
}

export async function listAutopayAliases(): Promise<AutopayAliasEntry[]> {
  const rows = await prisma.merchantAlias.findMany({
    where: { notes: 'autopay' },
    include: { category: true },
  });
  return rows
    .map((r) => {
      const category = asCategoryName(r.category?.name);
      if (!category) return null;
      const matchType = asMatchType(r.matchType);
      // AutopayAliasEntry only allows exact|substring (no regex)
      if (matchType === 'regex') return null;
      // Strip the "autopay:" prefix used as the dedup key in DB
      const pattern = r.rawPattern.startsWith('autopay:')
        ? r.rawPattern.slice('autopay:'.length)
        : r.rawPattern;
      return { pattern, matchType, category };
    })
    .filter((x): x is AutopayAliasEntry => x !== null);
}
