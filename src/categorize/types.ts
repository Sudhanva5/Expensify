// Categorization pipeline — types shared across alias/vpa/rules/orchestrator.

export const CATEGORIES = [
  'Travel',
  'Food',
  'Entertainment',
  'Groceries / Kirana Stores',
  'Personal Transfer (Peer-to-Peer)',
  'Investments',
  'Subscriptions',
] as const;
export type CategoryName = (typeof CATEGORIES)[number];

export type SignalSource =
  | 'alias'
  | 'autopay_alias'
  | 'vpa_shape'
  | 'user_rule'
  | 'merchant_pattern'
  // Set by recategorizeWithLocation after iOS uploads GPS and a nearby
  // Place's types map to one of our V1 categories. This is the *only*
  // signal source where merchantNormalized comes from Google Places.
  | 'places';

export interface CategorizationSignal {
  source: SignalSource;
  category: CategoryName;
  confidence: number;
  details: string;
  ruleId?: string;
}

export type CategorizationStatus = 'auto_resolved' | 'needs_review';

export interface CategorizationResult {
  signals: CategorizationSignal[];
  picked: CategorizationSignal | null;
  status: CategorizationStatus;
  merchantNormalized: string;
}

// === Aliases ===

export type AliasMatchType = 'exact' | 'substring' | 'regex';

export interface AliasEntry {
  pattern: string;
  matchType: AliasMatchType;
  canonical: string;
  category: CategoryName | null;
  notes?: string;
}

export interface AutopayAliasEntry {
  pattern: string;
  matchType: 'exact' | 'substring';
  category: CategoryName;
}

// === VPA shape ===

export type VpaShape = 'personal' | 'merchant' | 'unknown';

// === Rules ===

export const DAYS_OF_WEEK = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'] as const;
export type DayOfWeek = (typeof DAYS_OF_WEEK)[number];

export interface RuleConditions {
  direction?: 'in' | 'out';
  instrument?: string | string[];
  amountBetween?: [number, number]; // major units (rupees)
  timeOfDayBetween?: [string, string]; // "HH:MM" IST
  dayOfWeek?: DayOfWeek[];
  payeeContains?: string;
  payeeRegex?: string;
  payeeNotInAliasTable?: boolean;
  vpaShape?: VpaShape;
}

export interface UserRule {
  id: string;
  name: string;
  priority: number;
  enabled: boolean;
  conditions: RuleConditions;
  suggestCategory: CategoryName;
  confidence: number;
}

export interface RuleEvalContext {
  aliasMatched: boolean;
  vpaShape: VpaShape;
}

// === Threshold ===

export const AUTO_TAG_CONFIDENCE_THRESHOLD = 0.95;

// === Orchestrator context ===

export interface CategorizeContext {
  aliases: AliasEntry[];
  autopayAliases: AutopayAliasEntry[];
  routingPrefixes: string[];
  rules: UserRule[];
  // Optional pattern-learning lookup. When provided, categorize() checks
  // for an active pattern (≥3 user confirmations of the same merchant →
  // category) before running the rest of the tiers. Hit → auto-tag with
  // very high confidence. Injected from the DB by buildCategorizeContextFromDb.
  lookupMerchantPattern?: (
    merchantNormalized: string,
  ) => Promise<{ category: CategoryName; hitCount: number } | null>;
}

export interface Enrichment {
  // Reverse-geocoded city derived from the iOS GPS ping. Currently unused
  // by the categorize pipeline (Places resolution happens in a separate
  // recategorize step after location upload) but kept on the interface so
  // future tiers can use it without a signature change.
  city?: string;
}
