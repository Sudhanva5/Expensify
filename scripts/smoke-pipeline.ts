// Smoke test: parse a real sample email, categorize using the DB-backed
// context (no Groq/Brave configured — pure-rules path), and upsert.
//
// Run with: npx tsx scripts/smoke-pipeline.ts
//
// This is *not* a unit test — it requires a running Postgres with seed data.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseHdfcEmail } from '../src/parsers/hdfc/index.js';
import { categorize } from '../src/categorize/index.js';
import { buildCategorizeContextFromDb } from '../src/db/categorizeContext.js';
import { upsertTransaction } from '../src/db/transactions.js';
import { recordEmailMessage } from '../src/db/emailMessages.js';
import { prisma } from '../src/db/client.js';

const FIXTURE_DIR = join(import.meta.dirname, '../src/parsers/__fixtures__');

interface Sample {
  fixture: string;
  gmailMessageId: string;
  subject: string;
  receivedAt: Date;
}

const SAMPLES: Sample[] = [
  {
    fixture: 'cc-debit-bundl.txt',
    gmailMessageId: 'fake-msg-bundl-001',
    subject: 'You have done a transaction',
    receivedAt: new Date('2026-05-09T05:30:00Z'),
  },
  {
    fixture: 'cc-debit-swiggy.txt',
    gmailMessageId: 'fake-msg-swiggy-002',
    subject: 'You have done a transaction',
    receivedAt: new Date('2026-05-07T16:00:00Z'),
  },
  {
    fixture: 'cc-autopay-railway.txt',
    gmailMessageId: 'fake-msg-railway-003',
    subject: 'Auto-debit confirmation',
    receivedAt: new Date('2026-05-05T10:00:00Z'),
  },
  {
    fixture: 'upi-credit-sneha.txt',
    gmailMessageId: 'fake-msg-sneha-004',
    subject: 'You have received money',
    receivedAt: new Date('2026-05-10T12:00:00Z'),
  },
  {
    fixture: 'upi-debit-kirana.txt',
    gmailMessageId: 'fake-msg-kirana-005',
    subject: 'UPI Transaction Alert',
    receivedAt: new Date('2026-05-05T11:00:00Z'),
  },
];

async function main() {
  const ctx = await buildCategorizeContextFromDb();
  console.log(
    `Built CategorizeContext from DB: ${ctx.aliases.length} aliases, ` +
      `${ctx.autopayAliases.length} autopay, ${ctx.rules.length} rules`,
  );
  console.log();

  for (const s of SAMPLES) {
    const body = readFileSync(join(FIXTURE_DIR, s.fixture), 'utf-8');
    const parseResult = parseHdfcEmail({
      subject: s.subject,
      body,
      receivedAt: s.receivedAt,
    });

    if (!parseResult.ok) {
      console.log(`✗ ${s.fixture}: parser failed (${parseResult.reason})`);
      await recordEmailMessage({
        gmailMessageId: s.gmailMessageId,
        kind: 'unknown',
        parserVersion: null,
        rawSubject: s.subject,
        rawSnippet: body.slice(0, 200),
        parseError: parseResult.details,
      });
      continue;
    }

    const cat = await categorize(parseResult.data, ctx);

    await recordEmailMessage({
      gmailMessageId: s.gmailMessageId,
      kind: `hdfc_${parseResult.data.template}`,
      parserVersion: parseResult.parserVersion,
      rawSubject: s.subject,
      rawSnippet: body.slice(0, 200),
    });

    const result = await upsertTransaction({
      parsed: parseResult.data,
      categorization: cat,
      gmailMessageId: s.gmailMessageId,
      rawSubject: s.subject,
      rawSnippet: body.slice(0, 200),
    });

    const inrAmount =
      parseResult.data.amountInrMinor !== null
        ? `₹${(Number(parseResult.data.amountInrMinor) / 100).toFixed(2)}`
        : `${parseResult.data.currency} ${(Number(parseResult.data.amountMinor) / 100).toFixed(2)}`;

    const verdict = cat.picked
      ? `${cat.picked.category} (${cat.picked.source}, conf=${cat.picked.confidence.toFixed(2)})`
      : 'NO SIGNAL';
    const tag = cat.status === 'auto_resolved' ? '✓ auto' : '? review';

    console.log(
      `${tag}  ${s.fixture.padEnd(28)} ${inrAmount.padStart(14)}  →  ${verdict}  ${result.created ? '[new]' : '[idempotent]'}`,
    );
  }

  console.log();

  const summary = await prisma.transaction.groupBy({
    by: ['status'],
    _count: { _all: true },
  });
  console.log('Transaction counts by status:', summary);

  await prisma.$disconnect();
}

main().catch(async (e) => {
  console.error(e);
  await prisma.$disconnect();
  process.exit(1);
});
