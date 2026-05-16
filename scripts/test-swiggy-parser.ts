// Sanity check: pull one real Swiggy email and run the parser against
// it. Confirms the regexes work against actual production data, not
// just our hand-crafted test fixture.

import { google } from 'googleapis';
import { authorizedClient } from '../src/gmail/oauth.js';
import { extractSwiggy } from '../src/receipts/extractors.js';
import { prisma } from '../src/db/client.js';

interface GmailPart {
  mimeType?: string | null;
  body?: { data?: string | null } | null;
  parts?: GmailPart[] | null;
}

function findHtmlBody(payload: GmailPart | undefined | null): string | null {
  if (!payload) return null;
  const stack: GmailPart[] = [payload];
  while (stack.length > 0) {
    const part = stack.pop()!;
    if (part.mimeType === 'text/html' && part.body?.data) {
      return Buffer.from(part.body.data, 'base64url').toString('utf-8');
    }
    if (part.parts) for (const child of part.parts) stack.push(child);
  }
  return null;
}

function stripHtmlToText(html: string): string {
  return html
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|tr|li|h[1-6])>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/[ \t]+/g, ' ')
    .replace(/\n\s*\n+/g, '\n')
    .trim();
}

async function main() {
  const auth = await authorizedClient();
  const gmail = google.gmail({ version: 'v1', auth });

  // Look for a Swiggy email that's actually an order receipt, not a marketing one.
  const list = await gmail.users.messages.list({
    userId: 'me',
    q: 'from:swiggy.in subject:(order OR delivered) newer_than:6m',
    maxResults: 5,
  });
  const ids = list.data.messages?.map((m) => m.id).filter((x): x is string => !!x) ?? [];
  if (ids.length === 0) {
    console.log('No Swiggy receipt emails found.');
    return;
  }

  for (const id of ids) {
    const resp = await gmail.users.messages.get({ userId: 'me', id, format: 'full' });
    const subject = (resp.data.payload?.headers ?? [])
      .find((h) => h.name?.toLowerCase() === 'subject')?.value ?? '(no subject)';
    const html = findHtmlBody(resp.data.payload);
    if (!html) continue;
    const text = stripHtmlToText(html);

    console.log('═'.repeat(78));
    console.log(`Subject: ${subject}`);
    console.log('─'.repeat(78));

    const r = extractSwiggy(text);
    if (!r) {
      console.log('❌ Parser returned null (not a receipt or no section markers)');
      continue;
    }
    console.log(`✓ Order ID: ${r.orderId ?? '(none)'}`);
    console.log(`✓ Total:    ${r.amountInrMinor !== null ? '₹' + (Number(r.amountInrMinor) / 100).toFixed(2) : '(none)'}`);
    console.log(`✓ Items (${r.items?.length ?? 0}):`);
    for (const item of r.items ?? []) {
      console.log(`    - ${item.qty} × ${item.name} — ₹${item.priceInr}`);
    }
    console.log(`✓ Fees (${r.fees?.length ?? 0}):`);
    for (const fee of r.fees ?? []) {
      console.log(`    - ${fee.name}: ₹${fee.amountInr}`);
    }
    const meta = (r.meta ?? {}) as Record<string, { text: string; timestamp: string } | undefined>;
    if (meta.journeyFrom) {
      console.log(`✓ From: ${meta.journeyFrom.text} @ ${meta.journeyFrom.timestamp}`);
    }
    if (meta.journeyTo) {
      console.log(`✓ To:   ${meta.journeyTo.text} @ ${meta.journeyTo.timestamp}`);
    }
  }
}

main()
  .catch((err) => { console.error(err); process.exit(1); })
  .finally(async () => { await prisma.$disconnect(); });
