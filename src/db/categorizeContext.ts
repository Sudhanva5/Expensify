// Bridge: build a CategorizeContext from the database for the orchestrator.

import { listMerchantAliases, listAutopayAliases } from './aliases.js';
import { listEnabledRules } from './userRules.js';
import { findActivePattern } from './merchantPatterns.js';
import { ROUTING_PREFIXES } from '../categorize/seed.js';
import type { CategorizeContext } from '../categorize/types.js';

export async function buildCategorizeContextFromDb(): Promise<CategorizeContext> {
  const [aliases, autopayAliases, rules] = await Promise.all([
    listMerchantAliases(),
    listAutopayAliases(),
    listEnabledRules(),
  ]);

  return {
    aliases,
    autopayAliases,
    routingPrefixes: ROUTING_PREFIXES,
    rules,
    lookupMerchantPattern: findActivePattern,
  };
}
