// Budget threshold alerts. Called after a transaction's category is set or
// changed (initial insert + recategorize). For each configured threshold
// (default 80/100/110%), check if MTD spend has crossed it for the first
// time this month — if so, fire an APNs push and record a BudgetAlertFired
// row so we don't fire the same threshold twice.

import { prisma } from '../db/client.js';
import { sendBudgetAlertToAllDevices } from '../services/apns.js';

/// Run the budget-threshold check for a single category. No-op if the
/// category has no budget configured, the budget is disabled, or no
/// thresholds have been crossed since the last check.
export async function checkBudgetForCategory(categoryId: string): Promise<void> {
  const budget = await prisma.budget.findUnique({
    where: { categoryId },
    include: { category: { select: { name: true } } },
  });
  if (!budget || !budget.enabled) return;

  const limitMinor = Number(budget.monthlyLimitInr);
  if (limitMinor <= 0) return;

  const monthStart = startOfCurrentMonth();
  const yearMonth = `${monthStart.getUTCFullYear()}-${String(monthStart.getUTCMonth() + 1).padStart(2, '0')}`;

  const agg = await prisma.transaction.aggregate({
    where: {
      categoryId,
      direction: 'out',
      occurredAt: { gte: monthStart },
    },
    _sum: { amountInrMinor: true },
  });
  const spentMinor = agg._sum.amountInrMinor !== null ? Number(agg._sum.amountInrMinor) : 0;
  if (spentMinor <= 0) return;

  const ratio = spentMinor / limitMinor;

  // Walk thresholds high-to-low so the most severe alert wins if multiple
  // are newly crossed at once.
  const sortedThresholds = budget.alertThresholds
    .map((t) => Number(t))
    .sort((a, b) => b - a);

  for (const threshold of sortedThresholds) {
    if (ratio < threshold) continue;

    // Dedup: have we fired this threshold this month?
    const existing = await prisma.budgetAlertFired.findFirst({
      where: { budgetId: budget.id, yearMonth, threshold },
    });
    if (existing) continue;

    // Persist BEFORE sending so a race (two near-simultaneous transactions)
    // doesn't fire two pushes.
    await prisma.budgetAlertFired.create({
      data: { budgetId: budget.id, yearMonth, threshold },
    });

    await sendBudgetAlertToAllDevices({
      categoryName: budget.category.name,
      spent: spentMinor / 100,
      limit: limitMinor / 100,
      thresholdPct: Math.round(threshold * 100),
    });

    console.log(
      `[budgetAlerts] fired ${budget.category.name} at ${Math.round(threshold * 100)}% (₹${spentMinor / 100} of ₹${limitMinor / 100})`,
    );

    // We only fire one push per check — the highest threshold crossed.
    // If you happen to cross 80% and 100% in the same transaction (rare),
    // the next eligible threshold will fire on the next transaction.
    return;
  }
}

function startOfCurrentMonth(): Date {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
}
