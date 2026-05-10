// HDFC sometimes sends a HEADS-UP email a day before an autopay actually fires:
// "There is an upcoming E-mandate (Auto payment) of USD 23.60 ... will be debited
//  from your HDFC Bank Credit Card ending 3803 on 11/05/2026."
//
// The actual debit comes in a separate confirmation email later (handled by
// the regular cc_autopay parser). The preview is informational — we recognize
// it explicitly and tell the pipeline to skip cleanly, instead of letting it
// fall through as no_template_match (which would clutter parse-error logs).

import type { HdfcEmailInput, ParseResult, TemplateParser } from '../types.js';
import { PARSER_VERSION } from '../types.js';

const MARKER = /There is an upcoming E-mandate \(Auto payment\)/i;

export const tryParse: TemplateParser = (input: HdfcEmailInput): ParseResult | null => {
  if (!MARKER.test(input.body)) return null;
  return {
    ok: false,
    reason: 'not_a_transaction',
    details: 'upcoming-autopay preview; actual debit will arrive in a separate confirmation email',
    parserVersion: PARSER_VERSION,
  };
};
