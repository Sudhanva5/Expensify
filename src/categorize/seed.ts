// V1 seed data for routing prefixes, merchant aliases, and autopay aliases.
// At runtime this lives in DB tables; for now it's the source of truth.

import type { AliasEntry, AutopayAliasEntry } from './types.js';

export const ROUTING_PREFIXES: string[] = ['RAZ*', 'PAYU*', 'CCD*', 'BLLG*', 'BBPS*'];

export const SEED_ALIASES: AliasEntry[] = [
  // Food
  { pattern: 'BUNDL TECHNOLOGIES', matchType: 'exact', canonical: 'Swiggy', category: 'Food' },
  { pattern: 'Swiggy', matchType: 'substring', canonical: 'Swiggy', category: 'Food' },
  { pattern: 'Zomato', matchType: 'substring', canonical: 'Zomato', category: 'Food' },
  { pattern: 'EatFit', matchType: 'substring', canonical: 'EatFit', category: 'Food' },

  // Travel
  { pattern: 'ANI TECHNOLOGIES', matchType: 'exact', canonical: 'Ola', category: 'Travel' },
  { pattern: 'Ola', matchType: 'substring', canonical: 'Ola', category: 'Travel' },
  { pattern: 'UBER', matchType: 'substring', canonical: 'Uber', category: 'Travel' },
  { pattern: 'IRCTC', matchType: 'substring', canonical: 'IRCTC', category: 'Travel' },
  { pattern: 'INDIGO', matchType: 'substring', canonical: 'IndiGo', category: 'Travel' },
  { pattern: 'AKASA', matchType: 'substring', canonical: 'Akasa Air', category: 'Travel' },

  // Subscriptions
  { pattern: 'NETFLIX', matchType: 'substring', canonical: 'Netflix', category: 'Subscriptions' },
  { pattern: 'SPOTIFY', matchType: 'substring', canonical: 'Spotify', category: 'Subscriptions' },
  { pattern: 'CLAUDE', matchType: 'substring', canonical: 'Claude', category: 'Subscriptions' },
  { pattern: 'ANTHROPIC', matchType: 'substring', canonical: 'Anthropic', category: 'Subscriptions' },
  { pattern: 'OPENAI', matchType: 'substring', canonical: 'OpenAI', category: 'Subscriptions' },
  { pattern: 'CHATGPT', matchType: 'substring', canonical: 'ChatGPT', category: 'Subscriptions' },
  { pattern: 'YOUTUBE', matchType: 'substring', canonical: 'YouTube', category: 'Subscriptions' },
  { pattern: 'CURSOR', matchType: 'substring', canonical: 'Cursor', category: 'Subscriptions' },
  { pattern: 'GITHUB', matchType: 'substring', canonical: 'GitHub', category: 'Subscriptions' },

  // Entertainment
  { pattern: 'BOOKMYSHOW', matchType: 'substring', canonical: 'BookMyShow', category: 'Entertainment' },
  { pattern: 'PVR', matchType: 'substring', canonical: 'PVR', category: 'Entertainment' },
  { pattern: 'INOX', matchType: 'substring', canonical: 'INOX', category: 'Entertainment' },

  // Groceries
  { pattern: 'BIGBASKET', matchType: 'substring', canonical: 'BigBasket', category: 'Groceries / Kirana Stores' },
  { pattern: 'BLINKIT', matchType: 'substring', canonical: 'Blinkit', category: 'Groceries / Kirana Stores' },
  { pattern: 'ZEPTO', matchType: 'substring', canonical: 'Zepto', category: 'Groceries / Kirana Stores' },
  { pattern: 'INSTAMART', matchType: 'substring', canonical: 'Swiggy Instamart', category: 'Groceries / Kirana Stores' },
];

export const SEED_AUTOPAY_ALIASES: AutopayAliasEntry[] = [
  { pattern: 'Railway', matchType: 'exact', category: 'Travel' },
  { pattern: 'IRCTC', matchType: 'substring', category: 'Travel' },
  { pattern: 'Claude', matchType: 'exact', category: 'Subscriptions' },
  { pattern: 'Anthropic', matchType: 'substring', category: 'Subscriptions' },
  { pattern: 'OpenAI', matchType: 'substring', category: 'Subscriptions' },
  { pattern: 'ChatGPT', matchType: 'substring', category: 'Subscriptions' },
  { pattern: 'Netflix', matchType: 'substring', category: 'Subscriptions' },
  { pattern: 'Spotify', matchType: 'substring', category: 'Subscriptions' },
  { pattern: 'YouTube', matchType: 'substring', category: 'Subscriptions' },
  { pattern: 'Cursor', matchType: 'substring', category: 'Subscriptions' },
];
