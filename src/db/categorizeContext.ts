// Bridge: build a CategorizeContext from the database for the orchestrator.
// Pass groq/brave clients in from the caller (worker reads them from env).

import { listMerchantAliases, listAutopayAliases } from './aliases.js';
import { listEnabledRules } from './userRules.js';
import { ROUTING_PREFIXES } from '../categorize/seed.js';
import type { CategorizeContext } from '../categorize/types.js';
import type { GroqCategorizer } from '../categorize/groq.js';
import type { BraveSearchClient } from '../categorize/brave.js';

export interface BuildContextOptions {
  groq?: GroqCategorizer;
  brave?: BraveSearchClient;
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
    ...(opts.brave ? { brave: opts.brave } : {}),
  };
}
