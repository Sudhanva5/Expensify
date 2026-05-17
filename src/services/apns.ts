// APNs sender. Used to wake the iOS app for silent location requests, and
// (later) for visible pushes like the 7 PM digest and budget breach alerts.
//
// Auth: APNs Authentication Key (.p8 file) + Key ID + Team ID + Bundle ID.
// On Railway we keep the .p8 contents base64-encoded in APNS_KEY_CONTENT so
// the secret never lives on disk.
//
// Set on Railway:
//   APNS_KEY_CONTENT  = base64 of the .p8 file contents
//   APNS_KEY_ID       = 10-char Key ID from Apple Developer
//   APNS_TEAM_ID      = 10-char Team ID
//   APNS_BUNDLE_ID    = e.g. com.sudhanva.Expensify
//   APNS_USE_SANDBOX  = "true" while using a development build of the app,
//                       omit/false for App Store builds. (Apple uses two
//                       separate gateways for sandbox vs production.)

import apn from '@parse/node-apn';
import { prisma } from '../db/client.js';

let provider: apn.Provider | null = null;

function getProvider(): apn.Provider | null {
  if (provider) return provider;

  const keyContent = process.env['APNS_KEY_CONTENT'];
  const keyId = process.env['APNS_KEY_ID'];
  const teamId = process.env['APNS_TEAM_ID'];

  if (!keyContent || !keyId || !teamId) {
    console.warn(
      '[APNs] not configured (missing APNS_KEY_CONTENT/KEY_ID/TEAM_ID). Pushes will be skipped.',
    );
    return null;
  }

  // The .p8 we get from Apple is plain text PEM; we base64-wrap it for env.
  const decodedKey = Buffer.from(keyContent, 'base64').toString('utf-8');

  provider = new apn.Provider({
    token: { key: decodedKey, keyId, teamId },
    production: process.env['APNS_USE_SANDBOX'] !== 'true',
  });
  return provider;
}

interface LocationRequestPushArgs {
  apnsToken: string;
  transactionId: string;
}

/// Send a single silent push asking the device to upload its location for the
/// given transaction. Returns true on success, false otherwise (errors are
/// logged but never thrown — pipeline shouldn't fail just because a push did).
export async function sendLocationRequestPush(args: LocationRequestPushArgs): Promise<boolean> {
  const p = getProvider();
  if (!p) return false;

  const bundleId = process.env['APNS_BUNDLE_ID'];
  if (!bundleId) {
    console.warn('[APNs] APNS_BUNDLE_ID not set; skipping push');
    return false;
  }

  const note = new apn.Notification();
  note.topic = bundleId;
  // Silent push: content-available wakes the app without showing UI.
  note.contentAvailable = true;
  // priority 5 = power-conscious; 10 = immediate. 5 is right for silent pushes.
  note.priority = 5;
  note.payload = {
    kind: 'request_location',
    transactionId: args.transactionId,
  };
  // 90-second relevance window. If APNs can't deliver within that, the
  // user has almost certainly moved away from the transaction site —
  // posting their location 4 minutes later would tag the wrong place.
  // Better to let the push expire and pick the row up in the foreground
  // catchup (which only attaches location to <5min-old rows anyway).
  note.expiry = Math.floor(Date.now() / 1000) + 90;

  try {
    const result = await p.send(note, args.apnsToken);
    if (result.failed.length > 0) {
      console.error('[APNs] failed:', JSON.stringify(result.failed));
      // If Apple says the token is dead, drop it from the DB so we don't
      // keep trying to push to a ghost.
      for (const failed of result.failed) {
        const reason = failed.response?.reason;
        if (reason === 'BadDeviceToken' || reason === 'Unregistered') {
          await prisma.deviceToken
            .deleteMany({ where: { apnsToken: args.apnsToken } })
            .catch((err) => console.error('[APNs] failed to prune dead token:', err));
          console.log('[APNs] pruned dead token:', args.apnsToken.slice(0, 16));
        }
      }
      return false;
    }
    return true;
  } catch (err) {
    console.error('[APNs] send error:', err);
    return false;
  }
}

/// Convenience wrapper: load every registered device for the (single, V1) user
/// and fan out the push. Logs but never throws.
export async function requestLocationFromAllDevices(transactionId: string): Promise<void> {
  const devices = await prisma.deviceToken.findMany();
  if (devices.length === 0) {
    console.warn('[APNs] no registered devices; cannot request location for', transactionId);
    return;
  }
  for (const d of devices) {
    await sendLocationRequestPush({ apnsToken: d.apnsToken, transactionId });
  }
}

interface VisiblePushArgs {
  apnsToken: string;
  title: string;
  body: string;
  payload?: Record<string, unknown>;
}

/// Send a visible push (alert banner + sound). Used by budget threshold
/// alerts, the 7pm digest, etc. Unlike the silent location push, this one
/// shows a notification on the lock screen / banner.
export async function sendVisiblePush(args: VisiblePushArgs): Promise<boolean> {
  const p = getProvider();
  if (!p) return false;
  const bundleId = process.env['APNS_BUNDLE_ID'];
  if (!bundleId) {
    console.warn('[APNs] APNS_BUNDLE_ID not set; skipping push');
    return false;
  }

  const note = new apn.Notification();
  note.topic = bundleId;
  note.alert = { title: args.title, body: args.body };
  note.sound = 'default';
  note.priority = 10; // visible pushes go immediately
  note.payload = args.payload ?? {};

  try {
    const result = await p.send(note, args.apnsToken);
    if (result.failed.length > 0) {
      console.error('[APNs] visible push failed:', JSON.stringify(result.failed));
      for (const failed of result.failed) {
        const reason = failed.response?.reason;
        if (reason === 'BadDeviceToken' || reason === 'Unregistered') {
          await prisma.deviceToken
            .deleteMany({ where: { apnsToken: args.apnsToken } })
            .catch(() => {});
        }
      }
      return false;
    }
    return true;
  } catch (err) {
    console.error('[APNs] visible push error:', err);
    return false;
  }
}

interface BudgetAlertArgs {
  categoryName: string;
  spent: number; // rupees
  limit: number; // rupees
  thresholdPct: number; // 80, 100, 110...
}

/// Fan out a budget threshold push to every registered device.
export async function sendBudgetAlertToAllDevices(args: BudgetAlertArgs): Promise<void> {
  const devices = await prisma.deviceToken.findMany();
  if (devices.length === 0) return;

  const formatRupees = (v: number) =>
    new Intl.NumberFormat('en-IN', { maximumFractionDigits: 0 }).format(v);
  const spentStr = `₹${formatRupees(args.spent)}`;
  const limitStr = `₹${formatRupees(args.limit)}`;

  let title: string;
  let body: string;
  if (args.thresholdPct >= 110) {
    title = `${args.categoryName} is way over budget`;
    body = `You've spent ${spentStr} of your ${limitStr} monthly budget — ${args.thresholdPct}%.`;
  } else if (args.thresholdPct >= 100) {
    title = `${args.categoryName} hit your budget`;
    body = `You've spent ${spentStr} of your ${limitStr} monthly budget.`;
  } else {
    title = `${args.categoryName} approaching budget`;
    body = `You've spent ${spentStr} of your ${limitStr} monthly budget — ${args.thresholdPct}%.`;
  }

  for (const d of devices) {
    await sendVisiblePush({
      apnsToken: d.apnsToken,
      title,
      body,
      payload: {
        kind: 'budget_alert',
        categoryName: args.categoryName,
        thresholdPct: args.thresholdPct,
      },
    });
  }
}

interface ParserMissedAlertArgs {
  gmailMessageId: string;
  rawSubject: string;
  rawSnippet: string;
  parseError: string | null;
}

/// Fire a "parser missed an email" push when an HDFC alert arrived but
/// none of our six templates matched. The point is to detect HDFC
/// silently changing a template (which is exactly what happened on
/// 2026-05-17 with the new "is debited / ending NNNN / DD Mon, YYYY"
/// CC-UPI debit format — we missed a real ₹1275 transaction before
/// anyone noticed).
///
/// Dedupe rule: don't fire if there's already an `unknown_hdfc` row
/// within the past 24 hours — the user only needs to be told ONCE that
/// the parser is broken, not once per missed email. The persistent
/// `EmailMessage` row is the dedupe state; no extra table needed.
///
/// Fan-out reuses `sendVisiblePush` per registered device.
export async function sendParserMissedAlert(args: ParserMissedAlertArgs): Promise<void> {
  // Dedupe: count *other* unknown_hdfc rows in the last 24h. The current
  // row is excluded so the first miss after a 24h quiet period still
  // fires.
  const since = new Date(Date.now() - 24 * 3600 * 1000);
  const recentUnparsedOther = await prisma.emailMessage.count({
    where: {
      kind: 'unknown_hdfc',
      gmailMessageId: { not: args.gmailMessageId },
      receivedAt: { gte: since },
    },
  });
  if (recentUnparsedOther > 0) {
    console.log(
      `[parser-miss-alert] skipping push — ${recentUnparsedOther} other unparsed HDFC email(s) in the last 24h`,
    );
    return;
  }

  const devices = await prisma.deviceToken.findMany();
  if (devices.length === 0) return;

  const snippet = args.rawSnippet.slice(0, 110).trim();
  const title = '⚠ Parser missed an HDFC email';
  const body = snippet.length > 0
    ? `Likely template change. "${snippet}…"`
    : `Likely template change. Subject: "${args.rawSubject.slice(0, 80)}"`;

  for (const d of devices) {
    await sendVisiblePush({
      apnsToken: d.apnsToken,
      title,
      body,
      payload: {
        kind: 'parser_missed',
        gmailMessageId: args.gmailMessageId,
        parseError: args.parseError,
      },
    });
  }
  console.log(`[parser-miss-alert] fired for ${args.gmailMessageId} → ${devices.length} device(s)`);
}

/// Cleanup hook so tests / shutdown don't leak the HTTPS connection.
export function shutdownAPNs(): void {
  provider?.shutdown();
  provider = null;
}
