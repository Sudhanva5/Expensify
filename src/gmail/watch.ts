// Register Gmail's `users.watch` against our Pub/Sub topic. Watches expire
// after 7 days; a cron must re-register every ~6 days.

import { google } from 'googleapis';
import type { OAuth2Client } from 'google-auth-library';
import { prisma } from '../db/client.js';

export interface WatchOptions {
  topicName: string; // "projects/<gcp-project>/topics/<topic-name>"
  labelIds?: string[]; // restrict watch to specific labels (e.g., ["INBOX"])
}

export async function registerWatch(
  auth: OAuth2Client,
  opts: WatchOptions,
): Promise<{ historyId: string; expirationMs: number }> {
  const gmail = google.gmail({ version: 'v1', auth });
  const res = await gmail.users.watch({
    userId: 'me',
    requestBody: {
      topicName: opts.topicName,
      labelIds: opts.labelIds ?? ['INBOX'],
      labelFilterBehavior: 'INCLUDE',
    },
  });

  if (!res.data.historyId || !res.data.expiration) {
    throw new Error('Gmail watch returned without historyId or expiration');
  }

  const historyId = String(res.data.historyId);
  const expirationMs = Number(res.data.expiration);

  // Persist for the categorizer + heartbeat to read
  const existing = await prisma.gmailOauth.findFirst();
  if (existing) {
    await prisma.gmailOauth.update({
      where: { id: existing.id },
      data: {
        lastHistoryId: historyId,
        watchExpiresAt: new Date(expirationMs),
      },
    });
  }

  return { historyId, expirationMs };
}
