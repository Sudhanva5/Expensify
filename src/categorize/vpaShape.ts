// Classify a UPI VPA as merchant / personal / unknown by structural pattern.
//
// In V1 we kept this conservative — 5 hardcoded personal handles. But that
// missed most real-world VPAs (everyone's `superyes`, `axl`, `ybl` names
// fell into "unknown" and ended up in the review queue).
//
// This expanded version recognizes more personal-handle patterns AND
// distinguishes merchant-shape locals (q-prefix, paytm-* IDs, gpay-* IDs)
// from name-shape locals — same handle can host both depending on local.

import type { VpaShape } from './types.js';

/** Locals that are definitely merchant-shape, regardless of handle. */
const MERCHANT_LOCAL_RE = /^(q\d+|paytmqr\d+|paytm[\-.][a-z0-9]+|gpay[\-.][a-z0-9]+|upi[\-_]?[a-z0-9]+|swiggy|zomato|amazon|flipkart)/i;

/** Handles that almost always belong to personal accounts. */
const PERSONAL_HANDLES = new Set([
  // Bank-direct (UPI Lite-style)
  'oksbi', 'okaxis', 'okhdfcbank', 'okicici',
  // Apple Pay over UPI
  'apl',
  // PhonePe consumer
  'ybl', 'ibl',
  // PhonePe-on-other-banks (super* prefixes are PhonePe's white-label)
  'superyes', 'superaxis', 'superhdfc',
  // Paytm consumer (when local is name-shaped, not a paytmqr id)
  'paytm',
  // Axis SuperApp / Federal / Kotak / RBL / IDFC consumer
  'axl', 'axisb', 'fbl', 'kotak', 'kotak811',
  'rbl', 'idfcbank', 'idfcfirst', 'federalbank',
  // BHIM
  'upi',
  // GooglePay
  'okhdfc',
  // Yes Bank consumer
  'yesbank',
  // Jio Pay
  'jio',
]);

/** Handles that are explicitly merchant/business. */
const MERCHANT_HANDLES = new Set([
  'okbizaxis', 'okbizhdfcbank', 'okbizsbi', 'okbizicici',
  'yespay', 'yespayrazor',
  'ptys', 'pty',       // Paytm Q-code handles (paytmqr12345@ptys etc.)
  'razorpay',
  'payu',
  'instamojo',
  'ccavenue',
]);

export function classifyVpa(vpa: string): VpaShape {
  const trimmed = vpa.trim().toLowerCase();
  if (!trimmed.includes('@')) return 'unknown';

  const atIdx = trimmed.lastIndexOf('@');
  const local = trimmed.slice(0, atIdx);
  const handle = trimmed.slice(atIdx + 1);
  if (!local || !handle) return 'unknown';

  // Handle-level overrides (explicit business handles) win first.
  if (MERCHANT_HANDLES.has(handle)) return 'merchant';

  // Local-part shape: q-prefix, paytm-id, gpay-id, etc. are always merchants
  // regardless of handle.
  if (MERCHANT_LOCAL_RE.test(local)) return 'merchant';

  // Personal-handle path. Accept three local shapes:
  //   1. Name-shaped: starts with a letter, contains letters
  //      (sudeshhegde285@ybl, sagarprabhu251-1@okhdfcbank, sneha.r@oksbi)
  //   2. Phone-shaped local: pure digits or digit-prefix with -N suffix
  //      (9876543210@ybl, 7759973543-3@ybl) — personal phone on a personal handle
  //   3. Single-name handle: just letters, no digits
  if (PERSONAL_HANDLES.has(handle)) {
    const isNameShape = /^[a-z]/.test(local) && /[a-z]/.test(local);
    const isPhoneShape = /^\d{10}(-\d+)?$/.test(local);
    if (isNameShape || isPhoneShape) return 'personal';
  }

  return 'unknown';
}
