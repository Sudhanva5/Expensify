export const PARSER_VERSION = 'hdfc.v1';

export type EmailTemplate =
  | 'upi_credit'
  | 'cc_debit'
  | 'cc_autopay'
  | 'upi_debit';

export type Direction = 'in' | 'out';

export type ParseFailReason = 'no_template_match' | 'extraction_failed';

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
