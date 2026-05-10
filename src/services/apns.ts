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
  // 5-minute relevance window; if the device is offline longer it's stale.
  note.expiry = Math.floor(Date.now() / 1000) + 5 * 60;

  try {
    const result = await p.send(note, args.apnsToken);
    if (result.failed.length > 0) {
      console.error('[APNs] failed:', JSON.stringify(result.failed));
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

/// Cleanup hook so tests / shutdown don't leak the HTTPS connection.
export function shutdownAPNs(): void {
  provider?.shutdown();
  provider = null;
}
