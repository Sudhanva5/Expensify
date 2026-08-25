// The other half of receipt binding: sweep for receipts that arrived
// BEFORE their bank alert.
//
// processReceiptEmail() binds at receipt-ingest time, which only works when
// the HDFC transaction already exists. Merchants routinely beat the bank:
// redBus emailed a ticket at 15:06:24 and HDFC emailed the ₹1355 debit at
// 15:06:46, so the receipt row was written 21 seconds before there was
// anything to bind it to. `tryBindToTransaction` found no candidate,
// nothing ever looked again, and a receipt with an exact amount match sat
// orphaned next to its own transaction indefinitely.
//
// schema.prisma already listed "receipt may arrive before the HDFC alert
// (race)" as a reason `transactionId` is nullable — this closes it.
//
// Runs after every successful transaction insert, and over all history from
// scripts/rebind-orphan-receipts.ts. Both call the same
// `tryBindToTransaction`, so the "exactly one aligned candidate" rule and
// the three guards are identical in both directions by construction.

import { prisma } from '../db/client.js';
import { MATCH_WINDOW_MS } from '../receipts/binding.js';
import { tryBindToTransaction } from './processReceiptEmail.js';

export interface OrphanBindOutcome {
  receiptId: string;
  gmailMessageId: string;
  source: string;
  amountInrMinor: bigint;
  transactionId: string;
  reason: 'amount_and_window';
}

export interface OrphanSweepResult {
  examined: number;
  bound: OrphanBindOutcome[];
}

/**
 * Try to bind every orphan receipt whose arrival sits within the match
 * window of `occurredAt`.
 *
 * Receipts with no extractable amount are skipped — they can never satisfy
 * the exact-amount guard, so querying them would just burn work. (The
 * redBus "Tax Invoice" email is one of these: no "Ticket Price" line, so
 * the parser falls through to the universal extractor and finds nothing.)
 *
 * `dryRun` reports what it would do without writing, for the backfill
 * script's default mode.
 */
export async function bindOrphanReceiptsNear(
  occurredAt: Date,
  opts: { dryRun?: boolean } = {},
): Promise<OrphanSweepResult> {
  const orphans = await prisma.emailReceipt.findMany({
    where: {
      transactionId: null,
      amountInrMinor: { not: null },
      receivedAt: {
        gte: new Date(occurredAt.getTime() - MATCH_WINDOW_MS),
        lte: new Date(occurredAt.getTime() + MATCH_WINDOW_MS),
      },
    },
    select: {
      id: true,
      gmailMessageId: true,
      source: true,
      amountInrMinor: true,
      receivedAt: true,
    },
    orderBy: { receivedAt: 'asc' },
  });

  return bindOrphans(orphans, opts);
}

/**
 * Same sweep over EVERY orphan regardless of age — for the one-off backfill
 * across rows orphaned before the reverse bind existed.
 *
 * Only the *selection* is unbounded. Each candidate still has to match a
 * transaction inside MATCH_WINDOW_MS, so widening the net cannot loosen the
 * pairing rule.
 */
export async function bindAllOrphanReceipts(
  opts: { dryRun?: boolean } = {},
): Promise<OrphanSweepResult> {
  const orphans = await prisma.emailReceipt.findMany({
    where: { transactionId: null, amountInrMinor: { not: null } },
    select: {
      id: true,
      gmailMessageId: true,
      source: true,
      amountInrMinor: true,
      receivedAt: true,
    },
    orderBy: { receivedAt: 'asc' },
  });

  return bindOrphans(orphans, opts);
}

async function bindOrphans(
  orphans: {
    id: string;
    gmailMessageId: string;
    source: string;
    amountInrMinor: bigint | null;
    receivedAt: Date;
  }[],
  opts: { dryRun?: boolean },
): Promise<OrphanSweepResult> {
  const bound: OrphanBindOutcome[] = [];

  for (const r of orphans) {
    if (r.amountInrMinor === null) continue;

    const match = await tryBindToTransaction({
      amountInrMinor: r.amountInrMinor,
      receivedAt: r.receivedAt,
      source: r.source,
      // Windowed matches only. The relaxed pass exists for the forward
      // direction, where a receipt may land before the bank alert by more
      // than 90 minutes; here it would just pair same-amount rows that
      // happen to sit within a day of each other.
      allowRelaxed: false,
    });
    if (!match.transactionId) continue;
    if (match.reason !== 'amount_and_window') continue;

    if (!opts.dryRun) {
      // Guarded on transactionId still being null so two concurrent sweeps
      // (a webhook insert racing the backfill script) can't double-write.
      const updated = await prisma.emailReceipt.updateMany({
        where: { id: r.id, transactionId: null },
        data: { transactionId: match.transactionId },
      });
      if (updated.count === 0) continue;
    }

    bound.push({
      receiptId: r.id,
      gmailMessageId: r.gmailMessageId,
      source: r.source,
      amountInrMinor: r.amountInrMinor,
      transactionId: match.transactionId,
      reason: match.reason,
    });
  }

  return { examined: orphans.length, bound };
}
