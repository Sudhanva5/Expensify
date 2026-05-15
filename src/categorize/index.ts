// Categorization orchestrator.
// Runs the merchant pipeline (alias / VPA shape) and the user rule engine
// in parallel against a parsed transaction, picks the highest-confidence
// signal, and decides auto_resolved vs needs_review.

import type { ParsedTransaction } from '../parsers/hdfc/index.js';
import {
  stripRoutingPrefix,
  lookupAlias,
  lookupAutopayAlias,
} from './aliases.js';
import { classifyVpa } from './vpaShape.js';
import { evaluateRule } from './rules.js';
import type {
  CategorizationResult,
  CategorizationSignal,
  CategorizeContext,
  Enrichment,
  VpaShape,
} from './types.js';
import { AUTO_TAG_CONFIDENCE_THRESHOLD } from './types.js';

export async function categorize(
  tx: ParsedTransaction,
  ctx: CategorizeContext,
  _enrichment: Enrichment = {},
): Promise<CategorizationResult> {
  const merchantNormalized = stripRoutingPrefix(tx.merchantRaw, ctx.routingPrefixes);

  // UPI credits (incoming money) are essentially always P2P transfers from
  // another person. Auto-resolve without running the full pipeline — there's
  // nothing actionable for the user to review on an inflow. If a real
  // salary/refund flow becomes a need, the user can re-tag from a detail
  // view (planned, not built yet).
  if (tx.template === 'upi_credit') {
    return {
      signals: [{
        source: 'vpa_shape',
        category: 'Personal Transfer (Peer-to-Peer)',
        confidence: 0.99,
        details: 'Inflow auto-categorized as P2P',
      }],
      picked: {
        source: 'vpa_shape',
        category: 'Personal Transfer (Peer-to-Peer)',
        confidence: 0.99,
        details: 'Inflow auto-categorized as P2P',
      },
      status: 'auto_resolved',
      merchantNormalized,
    };
  }

  const signals: CategorizationSignal[] = [];
  const vpaShape: VpaShape = tx.vpa ? classifyVpa(tx.vpa) : 'unknown';

  // Pattern-learning shortcut — if the user has confirmed the SAME merchant
  // tagged the SAME way ≥3 times, we auto-tag forever from then on. Highest
  // confidence we emit. Runs before the alias table so user-trained
  // categorization wins over our hard-coded mappings (the user knows their
  // habits better than we do).
  if (ctx.lookupMerchantPattern) {
    const patternHit = await ctx.lookupMerchantPattern(merchantNormalized);
    if (patternHit) {
      signals.push({
        source: 'merchant_pattern',
        category: patternHit.category,
        confidence: 0.99,
        details: `Pattern: "${merchantNormalized}" → ${patternHit.category} (confirmed ${patternHit.hitCount}×)`,
      });
    }
  }

  // Tier 0 — autopay shortcut
  if (tx.isAutopay) {
    const hit = lookupAutopayAlias(merchantNormalized, ctx.autopayAliases);
    if (hit) {
      signals.push({
        source: 'autopay_alias',
        category: hit.category,
        confidence: 0.95,
        details: `Autopay: "${merchantNormalized}" → ${hit.category}`,
      });
    }
  }

  // Tier 1 — alias table
  const aliasHit = lookupAlias(merchantNormalized, ctx.aliases);
  let aliasMatched = false;
  if (aliasHit) {
    aliasMatched = true;
    if (aliasHit.category !== null) {
      signals.push({
        source: 'alias',
        category: aliasHit.category,
        confidence: 0.95,
        details: `Alias: "${merchantNormalized}" → ${aliasHit.canonical} (${aliasHit.category})`,
      });
    }
  }

  // Tier 2 — VPA shape
  //
  // Boosted to 0.95 (was 0.7) so personal-VPA transfers auto-tag as P2P
  // without sitting in the review queue. The old 0.7 cap was "wait for the
  // user to confirm" but in practice every UPI to a friend's personal
  // handle is a P2P — confirming 50× in a row added zero signal value.
  // False-positive risk: a small local merchant accepting a personal VPA
  // gets tagged P2P. Acceptable — the user can re-tag in one swipe, and
  // the merchant_patterns learning will move it to the right category
  // after 3 corrections.
  if (vpaShape === 'personal') {
    signals.push({
      source: 'vpa_shape',
      category: 'Personal Transfer (Peer-to-Peer)',
      confidence: 0.95,
      details: `VPA "${tx.vpa}" looks personal`,
    });
  }

  // Rules — parallel signal, always evaluated
  const ruleCtx = { aliasMatched, vpaShape };
  const sortedRules = [...ctx.rules]
    .filter((r) => r.enabled)
    .sort((a, b) => b.priority - a.priority);

  for (const rule of sortedRules) {
    if (evaluateRule(rule, tx, ruleCtx)) {
      signals.push({
        source: 'user_rule',
        category: rule.suggestCategory,
        confidence: rule.confidence,
        details: `Rule: ${rule.name}`,
        ruleId: rule.id,
      });
    }
  }

  // Note: this used to run two more tiers — Groq (Tier 3, LLM call with
  // merchant + amount + time) and Brave Search → Groq (Tier 4, grounded
  // by web snippets). Both removed. Groq was never configured in
  // production and added an LLM dependency we didn't need; Places +
  // alias + pattern-learning + VPA shape covers the actual catchable
  // cases. The fallback for unknown merchants is the review queue,
  // which the merchant_patterns layer learns from over time.

  const picked = pickHighestConfidence(signals);
  const status =
    picked && picked.confidence >= AUTO_TAG_CONFIDENCE_THRESHOLD
      ? 'auto_resolved'
      : 'needs_review';

  return { signals, picked, status, merchantNormalized };
}

function pickHighestConfidence(
  signals: CategorizationSignal[],
): CategorizationSignal | null {
  if (signals.length === 0) return null;
  return signals.reduce((best, s) => (s.confidence > best.confidence ? s : best));
}

export type {
  CategorizationResult,
  CategorizationSignal,
  CategorizeContext,
  CategoryName,
  UserRule,
  RuleConditions,
} from './types.js';
