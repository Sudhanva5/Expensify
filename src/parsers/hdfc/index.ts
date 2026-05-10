// HDFC email parser — dispatches to one of four template-specific parsers.
// Order: cc_autopay first (its marker is most specific), then the others.

import * as ccAutopay from './templates/cc-autopay.js';
import * as ccDebit from './templates/cc-debit.js';
import * as upiCredit from './templates/upi-credit.js';
import * as upiDebit from './templates/upi-debit.js';

import type { HdfcEmailInput, ParseResult, TemplateParser } from './types.js';
import { PARSER_VERSION } from './types.js';

const TEMPLATES: TemplateParser[] = [
  ccAutopay.tryParse,
  ccDebit.tryParse,
  upiCredit.tryParse,
  upiDebit.tryParse,
];

export function parseHdfcEmail(input: HdfcEmailInput): ParseResult {
  for (const tryParse of TEMPLATES) {
    const result = tryParse(input);
    if (result !== null) return result;
  }
  return {
    ok: false,
    reason: 'no_template_match',
    details: 'no HDFC template marker matched in email body',
    parserVersion: PARSER_VERSION,
  };
}

export type {
  HdfcEmailInput,
  ParseResult,
  ParsedTransaction,
  EmailTemplate,
  Direction,
} from './types.js';
export { PARSER_VERSION } from './types.js';
