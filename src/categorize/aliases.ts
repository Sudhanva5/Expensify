import type {
  AliasEntry,
  AliasMatchType,
  AutopayAliasEntry,
} from './types.js';

// Strip a known payment-routing prefix (RAZ*, PAYU*, etc.) from the raw
// merchant string so alias lookup sees the underlying merchant.
export function stripRoutingPrefix(raw: string, prefixes: string[]): string {
  const upper = raw.toUpperCase();
  for (const p of prefixes) {
    if (upper.startsWith(p.toUpperCase())) {
      return raw.slice(p.length);
    }
  }
  return raw;
}

export function lookupAlias(
  merchantNormalized: string,
  aliases: AliasEntry[],
): AliasEntry | null {
  const lower = merchantNormalized.toLowerCase();
  for (const a of aliases) {
    if (matches(lower, a.pattern.toLowerCase(), a.matchType)) {
      return a;
    }
  }
  return null;
}

export function lookupAutopayAlias(
  billName: string,
  aliases: AutopayAliasEntry[],
): AutopayAliasEntry | null {
  const lower = billName.toLowerCase();
  for (const a of aliases) {
    if (matches(lower, a.pattern.toLowerCase(), a.matchType)) {
      return a;
    }
  }
  return null;
}

function matches(input: string, pattern: string, type: AliasMatchType): boolean {
  switch (type) {
    case 'exact':
      return input === pattern;
    case 'substring':
      return input.includes(pattern);
    case 'regex':
      return new RegExp(pattern, 'i').test(input);
  }
}
