// Bridge: build a CategorizeContext from the database for the orchestrator.
// Pass the groq client in from the caller (worker reads it from env).

import { listMerchantAliases, listAutopayAliases } from './aliases.js';
import { listEnabledRules } from './userRules.js';
import { ROUTING_PREFIXES } from '../categorize/seed.js';
import type { CategorizeContext } from '../categorize/types.js';
import type { GroqCategorizer } from '../categorize/groq.js';

export interface BuildContextOptions {
  groq?: GroqCategorizer;
}

export async function buildCategorizeContextFromDb(
  opts: BuildContextOptions = {},
): Promise<CategorizeContext> {
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
    ...(opts.groq ? { groq: opts.groq } : {}),
  };
}
