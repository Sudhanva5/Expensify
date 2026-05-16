// Inspect one raw receipt body per sender. Lets us see what structured
// markup (if any) the merchant actually ships in their HTML — JSON-LD,
// microdata, RDFa, inline data attrs, or just plain HTML tables.
//
// Outputs counts of likely-structured patterns + a 1500-char head sample.

import { google } from 'googleapis';
import { authorizedClient } from '../src/gmail/oauth.js';
import { prisma } from '../src/db/client.js';

const SENDERS = ['swiggy.in', 'amazon.in', 'bookmyshow.com', 'uber.com', 'apple.com'];

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
    if (part.parts) {
      for (const child of part.parts) stack.push(child);
    }
  }
  return null;
}

async function main() {
  const auth = await authorizedClient();
  const gmail = google.gmail({ version: 'v1', auth });

  for (const sender of SENDERS) {
    console.log('\n' + '═'.repeat(78));
    console.log(`SAMPLE FROM: ${sender}`);
    console.log('═'.repeat(78));

    const list = await gmail.users.messages.list({
      userId: 'me',
      q: `from:${sender} newer_than:6m`,
      maxResults: 1,
    });
    const id = list.data.messages?.[0]?.id;
    if (!id) {
      console.log('(no messages found)');
      continue;
    }

    const resp = await gmail.users.messages.get({
      userId: 'me',
      id,
      format: 'full',
    });
    const html = findHtmlBody(resp.data.payload);
    if (!html) {
      console.log('(no HTML body)');
      continue;
    }

    // Structured-markup pattern counts.
    const ldjson = (html.match(/<script[^>]*type=["']application\/ld\+json["']/gi) ?? []).length;
    const microdata = (html.match(/itemscope|itemtype=["']https?:\/\/schema\.org/gi) ?? []).length;
    const rdfa = (html.match(/typeof=["']schema:Order/gi) ?? []).length;
    const orderId = (html.match(/Order\s*(?:ID|No|#)\s*:?\s*[\w-]+/gi) ?? []).length;
    const inrAmounts = (html.match(/₹\s*[\d,]+(?:\.\d+)?/g) ?? []).length;
    const subject = (resp.data.payload?.headers ?? [])
      .find((h) => h.name?.toLowerCase() === 'subject')?.value ?? '(no subject)';

    console.log(`Subject: ${subject}`);
    console.log(`HTML length: ${html.length} chars`);
    console.log(`Pattern counts:`);
    console.log(`  <script type=application/ld+json>:  ${ldjson}`);
    console.log(`  microdata (itemscope / schema.org): ${microdata}`);
    console.log(`  RDFa (typeof=schema:Order):         ${rdfa}`);
    console.log(`  "Order ID/No/#" mentions:           ${orderId}`);
    console.log(`  ₹ amounts:                          ${inrAmounts}`);

    // Strip HTML tags and emit ~600 chars of visible text so we can see
    // what data is actually in the body.
    const visible = html
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
    console.log(`\nVisible text preview (first 800 chars):`);
    console.log(visible.slice(0, 800));
  }
}

main()
  .catch((err) => {
    console.error(err);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
