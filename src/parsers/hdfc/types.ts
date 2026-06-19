export const PARSER_VERSION = 'hdfc.v1';

export type EmailTemplate =
  | 'upi_credit'
  | 'cc_debit'
  | 'cc_autopay'
  | 'upi_debit'
  | 'cc_upi_debit'
  | 'cc_upi_debit_v2'
  | 'cc_upi_debit_v3'
  | 'cc_thanks';

export type Direction = 'in' | 'out';

// 'not_a_transaction' = recognized email type that doesn't represent a real
// debit/credit (e.g., upcoming autopay preview). Caller should skip cleanly,
// not treat as an error.
export type ParseFailReason =
  | 'no_template_match'
  | 'extraction_failed'
  | 'not_a_transaction';

export interface HdfcEmailInput {
  subject: string;
  body: string;
  receivedAt: Date;
}

export interface ParsedTransaction {
  template: EmailTemplate;
  direction: Direction;
  instrument: string;

  amountMinor: bigint;
  currency: string;
  amountInrMinor: bigint | null;
  bankConvertedRate: number | null;

  merchantRaw: string;
  vpa: string | null;

  occurredAt: Date;

  externalRef: string | null;
  isAutopay: boolean;
}

export type ParseResult =
  | {
      ok: true;
      data: ParsedTransaction;
      parserVersion: string;
    }
  | {
      ok: false;
      reason: ParseFailReason;
      details: string;
      parserVersion: string;
    };

export type TemplateParser = (input: HdfcEmailInput) => ParseResult | null;
