// Per-transaction expansion helpers. The thin list/search tools project a
// lightweight transaction shape; these expand a row into rich blocks when
// the caller passes an `include: [...]` filter. Same helpers feed
// get_transaction(id) so the projection is identical no matter how the
// caller arrived at a tx.
//
// Each expander is null-safe — receipts/places/coords often missing.

import type { Prisma, EmailReceipt, Transaction } from '@prisma/client';
import { minorToInr } from './formatters.js';

/// Values accepted by the `include` array on list/search tools.
export const INCLUDE_VALUES = [
  'receipt',
  'places',
  'location',
  'fx',
  'email',
  'category',
] as const;
export type Include = (typeof INCLUDE_VALUES)[number];

/// What Prisma needs to fetch to support the given includes. `category`
/// is always required (the basic shape surfaces category name); receipts
/// are joined only when asked. Places, location, fx, email all live on
/// the Transaction row itself — no extra include needed for them.
export function prismaIncludeFor(includes: Set<Include>): Prisma.TransactionInclude {
  return {
    category: { select: { name: true } },
    ...(includes.has('receipt')
      ? { receipts: { orderBy: { receivedAt: 'desc' } } }
      : {}),
  };
}

type TransactionWithRelations = Transaction & {
  category: { name: string } | null;
  receipts?: EmailReceipt[];
};

/// Expand a single Transaction row into a JSON-friendly object with the
/// requested rich blocks attached. Lightweight base fields are ALWAYS
/// present; include[] gates the optional blocks.
export function expandTransaction(
  r: TransactionWithRelations,
  includes: Set<Include>,
): Record<string, unknown> {
  const out: Record<string, unknown> = {
    id: r.id,
    occurredAt: r.occurredAt.toISOString(),
    amountInr: minorToInr(r.amountInrMinor),
    currency: r.currency,
    direction: r.direction,
    instrument: r.instrument,
    merchant: r.merchantNormalized || r.merchantRaw,
    merchantRaw: r.merchantRaw,
    vpa: r.vpa,
    category: r.category?.name ?? null,
    confidence: r.confidence ? Number(r.confidence) : null,
    signalSource: r.signalSource,
    status: r.status,
    template: r.emailTemplate,
    // User-supplied freeform context typed via the iOS detail sheet.
    // Always present (null when empty) so the LLM doesn't have to
    // remember which tools project it; helps the LLM ground answers
    // in the user's own annotation when one exists.
    notes: r.notes,
  };

  if (includes.has('location')) {
    out.location = expandLocation(r);
  }
  if (includes.has('places')) {
    out.placesSuggestions = r.placesSuggestions;
  }
  if (includes.has('fx')) {
    out.fx = expandFx(r);
  }
  if (includes.has('email')) {
    out.email = expandEmail(r);
  }
  if (includes.has('receipt') && r.receipts) {
    out.receipts = r.receipts.map(expandReceipt);
  }
  return out;
}

/// Coords + status. Status alone is informative — `awaiting` means the
/// iPhone hasn't pinged yet; `missed` means the silent push timed out;
/// `not_applicable` means the row is autopay / online / inbound.
export function expandLocation(r: Transaction): Record<string, unknown> {
  return {
    lat: r.locationLat ? Number(r.locationLat) : null,
    lng: r.locationLng ? Number(r.locationLng) : null,
    status: r.locationStatus,
  };
}

/// FX block — present even on INR-only rows so the LLM can reason about
/// "was this in INR" uniformly. For INR-only the rate fields are null
/// and sourceAmountInr == amountInr.
export function expandFx(r: Transaction): Record<string, unknown> {
  return {
    sourceCurrency: r.currency,
    sourceAmount: minorToInr(r.amountMinor),
    inrAmount: minorToInr(r.amountInrMinor),
    bankConvertedRate: r.bankConvertedRate ? Number(r.bankConvertedRate) : null,
    marketRate: r.marketRate ? Number(r.marketRate) : null,
    fxMarkupPct: r.fxMarkupPct ? Number(r.fxMarkupPct) : null,
  };
}

/// Original HDFC email metadata. Body itself isn't stored (snippet only
/// — first ~200 chars). gmailMessageId is the idempotency key, useful
/// for re-fetching a body manually via Gmail UI.
export function expandEmail(r: Transaction): Record<string, unknown> {
  return {
    subject: r.rawSubject,
    snippet: r.rawSnippet,
    gmailMessageId: r.gmailMessageId,
  };
}

/// EmailReceipt → JSON. itemsJson / feesJson / metaJson are loose by
/// design — different parsers stamp different shapes. Pass them
/// through verbatim so the LLM can reason over whatever's there.
export function expandReceipt(r: EmailReceipt): Record<string, unknown> {
  return {
    id: r.id,
    source: r.source,
    subject: r.subject,
    snippet: r.snippet,
    receivedAt: r.receivedAt.toISOString(),
    fromAddress: r.fromAddress,
    amountInr: minorToInr(r.amountInrMinor),
    orderId: r.orderId,
    parserVersion: r.parserVersion,
    parseError: r.parseError,
    items: r.itemsJson,
    fees: r.feesJson,
    meta: r.metaJson,
  };
}
