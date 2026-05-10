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
  | 'groq'
  | 'brave_groq';

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
  // Optional Tier 3 — when undefined, Groq step is skipped entirely.
  groq?: import('./groq.js').GroqCategorizer;
  // Optional Tier 4 — Brave web search to ground Groq for unknown merchants.
  // Both groq AND brave must be present for Tier 4 to run.
  brave?: import('./brave.js').BraveSearchClient;
}

export interface Enrichment {
  // Reverse-geocoded city derived from the iOS GPS ping. Optional —
  // when missing, Brave search uses "India" as the geographic anchor.
  city?: string;
}
