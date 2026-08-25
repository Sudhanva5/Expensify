// Marketing / non-purchase filter for receipt-sender mail.
//
// `isReceiptSender()` matches on DOMAIN alone, so every mail from an
// allowlisted merchant enters the receipt pipeline. Most merchants send far
// more marketing than receipts from the same domain, so the EmailReceipt
// table filled up with perfume ads ("French Connection: A Scent That
// Stays ✨" from updates@myntra.com), feedback surveys, and price-drop
// blasts — 331 of 404 rows unbound.
//
// That is not merely untidy. The universal extractor happily pulls a
// number out of a promo: "Here's how you can get a FREE bus ticket! 👇"
// was stored with amountInrMinor = 85000, and a ₹850 figure invented by an
// ad is exactly the input that could bind to a real ₹850 debit.
//
// Mirrors MARKETING_SUBJECT_PATTERNS in gmail/messageBody.ts, including its
// hard-won lesson: NORMALISE WHITESPACE BEFORE MATCHING. Bulk senders emit
// non-breaking spaces, zero-width joiners and narrow no-break spaces inside
// subject lines, so a pattern written with a literal space silently fails
// against text that looks identical in a terminal.
//
// Deliberately NOT a positive "does it look like a receipt" test. A merchant
// changing its receipt template must degrade to an unparsed row we can
// re-extract later, never to a dropped email. This only rejects mail whose
// purpose is unmistakable.

/**
 * Shapes that mean "this is a record of a purchase", and which WIN over
 * every marketing rule below.
 *
 * This exists because the marketing patterns are necessarily fuzzy — a
 * campaign says "₹75 off" and so does a receipt that applied a ₹75 coupon.
 * Rather than hand-tune each pattern until it threads that needle, anything
 * carrying an unambiguous transactional marker is kept outright. Errs on
 * the side of a few extra promo rows, never on dropping a receipt.
 */
const TRANSACTIONAL_SUBJECT_PATTERNS: RegExp[] = [
  /\border\b[^.!?]{0,40}\b(delivered|shipped|cancelled|canceled|placed|confirmed|dispatched|out for delivery)\b/i,
  /\b(out for delivery|has been shipped)\b/i,
  /\breceipt\b/i,
  /\b(tax|gst)\s+invoice\b/i,
  /\bticket\s*[-–—]\s*[A-Z0-9]{6,}\b/i,
  /\bbooking\s+(confirmation|voucher|id)\b/i,
  /\bpayment\s+received\b/i,
  /\byour\s+e-?ticket\b/i,
];

/**
 * Sender addresses whose entire purpose is non-transactional. Matched on
 * the local part so `no_reply_feedback@redbus.in` is caught while
 * `no-reply@redbus.in` — which sends the actual tickets — is not.
 *
 * Every address matched here has zero bound receipts across the whole
 * corpus; none is a sender we have ever successfully read money from.
 */
const NON_TRANSACTIONAL_LOCALPART_RE =
  /(^|[._-])(feedback|research|survey|marketing|newsletter|promo|promotions|offers|deals|discover|otp|noreply-marketing)([._-]|$)/i;

/**
 * Subject shapes that are never a purchase confirmation.
 *
 * Kept to phrases whose intent is unambiguous. Broad commercial words
 * ("deal", "offer", "sale") are only matched in constructions that a
 * receipt would never use — "Sale is LIVE", "ends tonight" — because
 * "Your order … 50% off applied" is a real receipt.
 */
const MARKETING_SUBJECT_PATTERNS: RegExp[] = [
  // Post-trip / post-order solicitation. Not a receipt — the receipt
  // already arrived separately.
  /\brate your experience\b/i,
  /\bvaluable feedback\b/i,
  /\bhow was your (travel|trip|experience|order)\b/i,
  /\bfeedback survey\b/i,
  /\bshare your thoughts\b/i,
  /\btell us what you think\b/i,
  /\bvalue your (insights|feedback)\b/i,
  /\bwe have a question for you\b/i,
  /\brate (your|this) (order|ride|stay)\b/i,
  /\bwe need your opinion\b/i,
  /\breview your recent\b/i,
  /\bfinal call\b/i,

  // Pre-trip reminders. redBus sends "here's everything you need for your
  // trip to X" days AFTER the ticket; it carries no payable amount.
  /\bhere.?s everything you need for your trip\b/i,
  /\bregarding your recent\b/i,

  // Campaign language.
  /\bsale\b.{0,20}\b(is\s+)?live\b/i,
  /\bsale\b.{0,20}\b(ends|starts|starting)\b/i,
  /\b(ends|ending)\s+(tonight|today|soon)\b/i,
  /\blive now\b/i,
  /\bprice drop\b/i,
  /\blimited[-\s]time\b/i,
  /\blimited period\b/i,
  /\bexclusive offer\b/i,
  /\b\d{1,3}\s*%\s*off\b/i,
  // NB: no leading \b before ₹ — it is not a word character, so \b would
  // never match there. "We just got you ₹75 off" went uncaught for exactly
  // that reason.
  /(?:₹|\brs\.?|\binr)\s*[\d,]+\s*off\b/i,
  /\bstarting at\s*(?:₹|rs\.?|inr)/i,  // same note as above: ₹ needs no \b
  /\bget a free\b/i,
  /\bfree\s+(?:bus\s+)?ticket\b/i,
  /\bshop now\b/i,
  /\bpay later\b/i,
  /\btrend edit\b/i,
  /\bunwrap\b/i,
  /\bvoucher on your spends\b/i,

  // Account / status mail that isn't money leaving.
  /\byou are now a\b.{0,30}\bmember\b/i,
  /\bpayment failed\b/i,
  /\bwelcome to\b/i,
  /\bverify your\b/i,
  /\byour otp\b/i,
];

/**
 * Collapse the whitespace zoo bulk senders use, so patterns written with a
 * literal space actually match. U+00A0 no-break space, U+202F narrow
 * no-break space, U+200B/U+200D zero-width space & joiner, U+FEFF BOM.
 */
export function normalizeSubject(subject: string): string {
  return subject
    .replace(/[   - ]/g, ' ')
    .replace(/[​‌‍﻿]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

export interface MarketingCheck {
  isMarketing: boolean;
  reason?: 'non_transactional_sender' | 'marketing_subject';
  matched?: string;
}

/**
 * Is this mail from a receipt-sending domain actually marketing, feedback,
 * or account noise rather than a purchase?
 *
 * Biased toward keeping mail: a false positive silently discards a real
 * receipt, while a false negative just leaves one more unparsed row in a
 * table that already tolerates them.
 */
export function detectMarketingReceipt(
  fromAddress: string | null,
  subject: string,
): MarketingCheck {
  const normalized = normalizeSubject(subject);

  // Transactional markers win over every rule below — see
  // TRANSACTIONAL_SUBJECT_PATTERNS for why.
  for (const re of TRANSACTIONAL_SUBJECT_PATTERNS) {
    if (re.test(normalized)) return { isMarketing: false };
  }

  const localPart = (fromAddress ?? '')
    .replace(/^[^<]*</, '')
    .replace(/>.*$/, '')
    .split('@')[0] ?? '';
  const senderHit = localPart.match(NON_TRANSACTIONAL_LOCALPART_RE);
  if (senderHit) {
    return {
      isMarketing: true,
      reason: 'non_transactional_sender',
      matched: senderHit[0],
    };
  }

  for (const re of MARKETING_SUBJECT_PATTERNS) {
    const m = normalized.match(re);
    if (m) {
      return { isMarketing: true, reason: 'marketing_subject', matched: m[0] };
    }
  }

  return { isMarketing: false };
}
