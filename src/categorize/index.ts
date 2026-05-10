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

// Tier 4 fires only if Tier 3 hasn't produced at least this much confidence.
const TIER4_CONFIDENCE_FLOOR = 0.85;

export async function categorize(
  tx: ParsedTransaction,
  ctx: CategorizeContext,
  enrichment: Enrichment = {},
): Promise<CategorizationResult> {
  const signals: CategorizationSignal[] = [];

  const merchantNormalized = stripRoutingPrefix(tx.merchantRaw, ctx.routingPrefixes);
  const vpaShape: VpaShape = tx.vpa ? classifyVpa(tx.vpa) : 'unknown';

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
  if (vpaShape === 'personal') {
    signals.push({
      source: 'vpa_shape',
      category: 'Personal Transfer (Peer-to-Peer)',
      confidence: 0.7,
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

  // Tier 3 — Groq alone. Only call if no auto-tag-eligible signal already exists.
  const hasAutoTag = signals.some(
    (s) => s.confidence >= AUTO_TAG_CONFIDENCE_THRESHOLD,
  );

  const groqInputCommon = {
    merchantRaw: tx.merchantRaw,
    merchantNormalized,
    vpa: tx.vpa,
    amountInr:
      tx.amountInrMinor !== null
        ? Number(tx.amountInrMinor) / 100
        : Number(tx.amountMinor) / 100,
    occurredAt: tx.occurredAt,
    direction: tx.direction,
    instrument: tx.instrument,
    isAutopay: tx.isAutopay,
  };

  if (ctx.groq && !hasAutoTag) {
    const out = await ctx.groq.categorize(groqInputCommon);
    if (out.category !== null) {
      signals.push({
        source: 'groq',
        category: out.category,
        confidence: out.confidence,
        details: `Groq: ${out.rationale}`,
      });
    }
  }

  // Tier 4 — Brave Search → Groq synthesis. Only fires if:
  //   - both groq + brave are configured
  //   - we still don't have an auto-tag-eligible signal
  //   - tier 3 didn't already give us a confidence above the floor
  const tier3StrongEnough = signals.some(
    (s) => s.source === 'groq' && s.confidence >= TIER4_CONFIDENCE_FLOOR,
  );
  if (
    ctx.groq &&
    ctx.brave &&
    !hasAutoTag &&
    !tier3StrongEnough
  ) {
    const webContext = await ctx.brave.search({
      merchant: merchantNormalized,
      city: enrichment.city,
    });
    if (webContext.length > 0) {
      const out = await ctx.groq.categorize({
        ...groqInputCommon,
        webContext,
      });
      if (out.category !== null) {
        signals.push({
          source: 'brave_groq',
          category: out.category,
          confidence: out.confidence,
          details: `Brave+Groq: ${out.rationale}`,
        });
      }
    }
  }

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
