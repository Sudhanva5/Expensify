// One-shot diagnostic: sample receipt emails from the user's Gmail and check
// how many include `<script type="application/ld+json">` blocks with Order
// markup. Tells us whether the schema.org-first receipts feature design
// actually works in practice for THIS user's merchants.
//
// Usage:
//   DATABASE_URL=... GOOGLE_OAUTH_CLIENT_ID=... GOOGLE_OAUTH_CLIENT_SECRET=... \
//     GOOGLE_OAUTH_REDIRECT_URI=... npx tsx scripts/check-jsonld-adoption.ts
//
// Reads nothing from the DB except the Gmail OAuth refresh token (stored
// by `npx tsx scripts/gmail-auth.ts`). Does NOT mutate anything.
//
// Output: per-sender table showing receipt count + JSON-LD coverage rate,
// plus a sample of one extracted Order object per sender (so we can see
// what fields are populated).

import { google } from 'googleapis';
import { authorizedClient } from '../src/gmail/oauth.js';
import { prisma } from '../src/db/client.js';

// Senders we treat as receipt-emitters. Anything from these domains is
// counted toward the adoption rate. Add more as needed — adoption rate
// only goes up if more senders ship JSON-LD.
const RECEIPT_SENDERS = [
  'swiggy.in',
  'zomato.com',
  'amazon.in',
  'bookmyshow.com',
  'uber.com',
  'olacabs.com',
  'rapido.bike',
  'makemytrip.com',
  'goibibo.com',
  'cleartrip.com',
  'airbnb.com',
  'flipkart.com',
  'myntra.com',
  'jiomart.com',
  'bigbasket.com',
  'blinkit.com',
  'zepto.com',
  'apple.com',
  'netflix.com',
  'spotify.com',
];

const MAX_MESSAGES_PER_SENDER = 10;

interface SenderStats {
  total: number;
  withJsonLd: number;
  withOrderSchema: number;
  sampleOrder: unknown | null;
  parseErrors: number;
}

async function main() {
  const auth = await authorizedClient();
  const gmail = google.gmail({ version: 'v1', auth });

  console.log(`Checking JSON-LD adoption across ${RECEIPT_SENDERS.length} senders, ${MAX_MESSAGES_PER_SENDER} messages each…\n`);

  const stats: Record<string, SenderStats> = {};

  for (const sender of RECEIPT_SENDERS) {
    const senderStats: SenderStats = {
      total: 0,
      withJsonLd: 0,
      withOrderSchema: 0,
      sampleOrder: null,
      parseErrors: 0,
    };
    stats[sender] = senderStats;

    // Search this sender; limit to the last 6 months for relevance.
    const list = await gmail.users.messages.list({
      userId: 'me',
      q: `from:${sender} newer_than:6m`,
      maxResults: MAX_MESSAGES_PER_SENDER,
    });
    const ids = list.data.messages?.map((m) => m.id).filter((x): x is string => !!x) ?? [];
    if (ids.length === 0) continue;

    for (const id of ids) {
      senderStats.total++;
      try {
        const fullResp = await gmail.users.messages.get({
          userId: 'me',
          id,
          format: 'full',
        });
        const htmlBody = findHtmlBody(fullResp.data.payload);
        if (!htmlBody) continue;

        const blocks = extractJsonLdBlocks(htmlBody);
        if (blocks.length === 0) continue;
        senderStats.withJsonLd++;

        for (const block of blocks) {
          try {
            const parsed = JSON.parse(block);
            if (looksLikeOrder(parsed)) {
              senderStats.withOrderSchema++;
              if (!senderStats.sampleOrder) {
                senderStats.sampleOrder = parsed;
              }
              break; // stop at first Order block per message
            }
          } catch {
            senderStats.parseErrors++;
          }
        }
      } catch (err) {
        // Skip messages we can't fetch (deleted, perms, whatever).
        const msg = (err as Error).message;
        console.warn(`  skip ${sender}/${id.slice(0, 8)}: ${msg.slice(0, 80)}`);
      }
    }
  }

  // Report.
  console.log('\n' + '═'.repeat(78));
  console.log(`${pad('SENDER', 24)} ${pad('TOTAL', 6)} ${pad('JSON-LD', 8)} ${pad('ORDER', 8)} ${pad('% ORDER', 8)}`);
  console.log('─'.repeat(78));
  for (const sender of RECEIPT_SENDERS) {
    const s = stats[sender]!;
    if (s.total === 0) continue;
    const pct = ((s.withOrderSchema / s.total) * 100).toFixed(0);
    console.log(
      `${pad(sender, 24)} ${pad(String(s.total), 6)} ${pad(String(s.withJsonLd), 8)} ${pad(String(s.withOrderSchema), 8)} ${pad(pct + '%', 8)}`,
    );
  }
  console.log('═'.repeat(78));

  // Aggregate stats.
  const totals = Object.values(stats).reduce(
    (acc, s) => ({
      total: acc.total + s.total,
      withJsonLd: acc.withJsonLd + s.withJsonLd,
      withOrderSchema: acc.withOrderSchema + s.withOrderSchema,
    }),
    { total: 0, withJsonLd: 0, withOrderSchema: 0 },
  );
  if (totals.total > 0) {
    const overallPct = ((totals.withOrderSchema / totals.total) * 100).toFixed(1);
    console.log(`\nOverall: ${totals.withOrderSchema}/${totals.total} (${overallPct}%) receipts have schema.org Order markup`);
  }

  // Print one sample Order per sender that emitted any.
  console.log('\n' + '═'.repeat(78));
  console.log('SAMPLE EXTRACTED ORDER PER SENDER (truncated to ~600 chars each)');
  console.log('═'.repeat(78));
  for (const sender of RECEIPT_SENDERS) {
    const sample = stats[sender]?.sampleOrder;
    if (!sample) continue;
    console.log(`\n── ${sender} ──`);
    const json = JSON.stringify(sample, null, 2);
    console.log(json.length > 600 ? json.slice(0, 600) + '\n... [truncated]' : json);
  }
}

// === Helpers ===

function pad(s: string, n: number): string {
  return s.length >= n ? s : s + ' '.repeat(n - s.length);
}

interface GmailPart {
  mimeType?: string | null;
  body?: { data?: string | null } | null;
  parts?: GmailPart[] | null;
}

function findHtmlBody(payload: GmailPart | undefined | null): string | null {
  if (!payload) return null;
  // Walk the MIME tree, depth-first, return the first text/html body found.
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

/**
 * Extract every `<script type="application/ld+json">...</script>` block from
 * an HTML string. Tolerant to single/double quotes and extra whitespace.
 */
function extractJsonLdBlocks(html: string): string[] {
  const re =
    /<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    const content = m[1]?.trim();
    if (content) out.push(content);
  }
  return out;
}

/**
 * Recognize an Order-ish schema.org object. Accepts the canonical Order
 * type and also lenient variants (some merchants ship Invoice, others
 * embed Order inside @graph).
 */
function looksLikeOrder(parsed: unknown): boolean {
  if (!parsed || typeof parsed !== 'object') return false;
  const obj = parsed as Record<string, unknown>;

  const type = obj['@type'];
  if (typeof type === 'string') {
    return /^(Order|Invoice|Reservation|FoodEstablishmentReservation|FlightReservation|LodgingReservation|EventReservation)$/i.test(type);
  }

  // @graph variant: array of typed objects
  const graph = obj['@graph'];
  if (Array.isArray(graph)) {
    return graph.some(looksLikeOrder);
  }

  return false;
}

main()
  .catch((err) => {
    console.error(err);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
