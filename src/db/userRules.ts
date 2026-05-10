// Repository: load enabled user rules and convert to the shape the
// rule evaluator expects.

import { prisma } from './client.js';
import type { UserRule, RuleConditions, CategoryName } from '../categorize/types.js';
import { CATEGORIES } from '../categorize/types.js';

const VALID_CATEGORY_SET = new Set<string>(CATEGORIES);

export async function listEnabledRules(): Promise<UserRule[]> {
  const rows = await prisma.userRule.findMany({
    where: { enabled: true },
    include: { category: true },
    orderBy: { priority: 'desc' },
  });
  return rows
    .map((r) => {
      if (!VALID_CATEGORY_SET.has(r.category.name)) return null;
      // conditions is JSONB; we trust whoever wrote it (admin/user).
      // A future hardening pass can validate with Zod at read time.
      return {
        id: r.id,
        name: r.name,
        priority: r.priority,
        enabled: r.enabled,
        conditions: r.conditions as unknown as RuleConditions,
        suggestCategory: r.category.name as CategoryName,
        confidence: Number(r.defaultConfidence),
      };
    })
    .filter((x): x is UserRule => x !== null);
}
