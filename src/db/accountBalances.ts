// AccountBalance reads/writes. One row per instrument; upsert on every
// balance email so the latest known value is always discoverable
// without joining a history table.

import { prisma } from './client.js';
import type { AccountBalance } from '@prisma/client';

export interface UpsertBalanceInput {
  instrument: string;
  balanceInrMinor: bigint;
  asOf: Date;
  gmailMessageId: string;
  source?: string;
}

/// Insert or update the balance row for an instrument.
///
/// Returns `null` when the incoming email is older than what's stored —
/// stale push delivery / out-of-order Pub/Sub shouldn't overwrite a
/// fresher reading. Returns the row otherwise.
export async function upsertAccountBalance(
  input: UpsertBalanceInput,
): Promise<AccountBalance | null> {
  const existing = await prisma.accountBalance.findUnique({
    where: { instrument: input.instrument },
  });
  if (existing && existing.asOf.getTime() > input.asOf.getTime()) {
    return null;
  }
  return prisma.accountBalance.upsert({
    where: { instrument: input.instrument },
    create: {
      instrument: input.instrument,
      balanceInrMinor: input.balanceInrMinor,
      asOf: input.asOf,
      source: input.source ?? 'hdfc_balance_email',
      gmailMessageId: input.gmailMessageId,
    },
    update: {
      balanceInrMinor: input.balanceInrMinor,
      asOf: input.asOf,
      source: input.source ?? 'hdfc_balance_email',
      gmailMessageId: input.gmailMessageId,
    },
  });
}

export async function listAccountBalances(): Promise<AccountBalance[]> {
  return prisma.accountBalance.findMany({
    orderBy: { instrument: 'asc' },
  });
}
