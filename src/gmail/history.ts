// Given a Gmail historyId, fetch all message IDs added since, then fetch
// each message's full content. Returns the parsed/extracted form ready for
// the worker to feed to the parser.

import { google } from 'googleapis';
import type { OAuth2Client } from 'google-auth-library';
import { extractMessage, type ExtractedMessage } from './messageBody.js';
import { prisma } from '../db/client.js';

export async function fetchNewMessagesSince(
  auth: OAuth2Client,
  startHistoryId: string,
): Promise<{ messages: ExtractedMessage[]; latestHistoryId: string | null }> {
  const gmail = google.gmail({ version: 'v1', auth });

  const newMessageIds = new Set<string>();
  let pageToken: string | undefined;
  let latestHistoryId: string | null = null;

  // Walk the history pages
  do {
    const res = await gmail.users.history.list({
      userId: 'me',
      startHistoryId,
      historyTypes: ['messageAdded'],
      ...(pageToken !== undefined ? { pageToken } : {}),
    });
    if (res.data.historyId) latestHistoryId = String(res.data.historyId);
    for (const entry of res.data.history ?? []) {
      for (const m of entry.messagesAdded ?? []) {
        if (m.message?.id) newMessageIds.add(m.message.id);
      }
    }
    pageToken = res.data.nextPageToken ?? undefined;
  } while (pageToken);

  // Fetch each new message in full
  const messages: ExtractedMessage[] = [];
  for (const id of newMessageIds) {
    try {
      const res = await gmail.users.messages.get({
        userId: 'me',
        id,
        format: 'full',
      });
      messages.push(extractMessage(res.data));
    } catch (err) {
      // Common: 404 because message was deleted between history.list and get.
      // Log and skip — don't fail the whole batch for one missing message.
      console.warn(`Failed to fetch Gmail message ${id}:`, (err as Error).message);
    }
  }

  return { messages, latestHistoryId };
}

export async function persistLatestHistoryId(historyId: string): Promise<void> {
  const existing = await prisma.gmailOauth.findFirst();
  if (existing) {
    await prisma.gmailOauth.update({
      where: { id: existing.id },
      data: { lastHistoryId: historyId },
    });
  }
}

export async function loadLastHistoryId(): Promise<string | null> {
  const row = await prisma.gmailOauth.findFirst();
  return row?.lastHistoryId ?? null;
}
