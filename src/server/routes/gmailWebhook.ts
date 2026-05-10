// Pub/Sub push endpoint. Google posts a signed JWT in the Authorization
// header; we verify it before doing any work, then decode the inner payload.
//
// IMPORTANT: ack the request fast (<10s). Do the heavy lifting in a background
// promise. Pub/Sub considers any non-2xx a failure and will redeliver.

import type { FastifyInstance, FastifyRequest } from 'fastify';
import { OAuth2Client } from 'google-auth-library';
import { decodeGmailPushBody } from '../../gmail/pubsubMessage.js';
import {
  fetchNewMessagesSince,
  loadLastHistoryId,
  persistLatestHistoryId,
} from '../../gmail/history.js';
import { authorizedClient } from '../../gmail/oauth.js';
import { processGmailMessage } from '../../pipeline/processGmailMessage.js';
import { buildCategorizeContextFromDb } from '../../db/categorizeContext.js';
import { requestLocationFromAllDevices } from '../../services/apns.js';
import {
  HttpGroqCategorizer,
  type GroqCategorizer,
} from '../../categorize/groq.js';
import {
  HttpBraveSearchClient,
  type BraveSearchClient,
} from '../../categorize/brave.js';

const tokenVerifier = new OAuth2Client();

async function verifyPubsubJwt(req: FastifyRequest): Promise<boolean> {
  const audience = process.env['GOOGLE_PUBSUB_VERIFICATION_AUDIENCE'];
  if (!audience) {
    // In dev (no audience configured), skip verification but log loudly.
    req.log.warn('GOOGLE_PUBSUB_VERIFICATION_AUDIENCE not set — skipping JWT verification');
    return true;
  }
  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) return false;
  const token = auth.slice('Bearer '.length);
  try {
    const ticket = await tokenVerifier.verifyIdToken({ idToken: token, audience });
    const payload = ticket.getPayload();
    return payload?.email_verified === true || !!payload?.email;
  } catch (err) {
    req.log.warn({ err }, 'Pub/Sub JWT verification failed');
    return false;
  }
}

function buildOptionalGroq(): GroqCategorizer | undefined {
  const key = process.env['GROQ_API_KEY'];
  if (!key) return undefined;
  return new HttpGroqCategorizer({ apiKey: key });
}

function buildOptionalBrave(): BraveSearchClient | undefined {
  const key = process.env['BRAVE_SEARCH_API_KEY'];
  if (!key) return undefined;
  return new HttpBraveSearchClient({ apiKey: key });
}

export async function gmailWebhookRoute(app: FastifyInstance): Promise<void> {
  app.post('/gmail', async (req, reply) => {
    if (!(await verifyPubsubJwt(req))) {
      return reply.code(401).send({ error: 'Pub/Sub JWT verification failed' });
    }

    let notification;
    try {
      notification = decodeGmailPushBody(req.body);
    } catch (err) {
      req.log.warn({ err }, 'failed to decode Pub/Sub envelope');
      // Respond 2xx so Pub/Sub doesn't redeliver malformed payloads forever.
      return reply.code(200).send({ ok: false, reason: 'malformed' });
    }

    // Ack immediately; do the work in the background.
    void runInBackground(notification.historyId).catch((err) =>
      req.log.error({ err }, 'background processing failed'),
    );

    return { ok: true };
  });

  async function runInBackground(incomingHistoryId: string) {
    const auth = await authorizedClient();

    // Use the LAST persisted historyId as the starting point — Pub/Sub messages
    // can arrive out of order and we want to fetch everything since we last
    // checked, not just the message that triggered this push.
    const startHistoryId = (await loadLastHistoryId()) ?? incomingHistoryId;

    const { messages, latestHistoryId } = await fetchNewMessagesSince(
      auth,
      startHistoryId,
    );

    if (messages.length === 0) {
      if (latestHistoryId) await persistLatestHistoryId(latestHistoryId);
      return;
    }

    const ctx = await buildCategorizeContextFromDb({
      ...(buildOptionalGroq() ? { groq: buildOptionalGroq()! } : {}),
      ...(buildOptionalBrave() ? { brave: buildOptionalBrave()! } : {}),
    });

    for (const msg of messages) {
      const outcome = await processGmailMessage(msg, ctx);
      app.log.info({ outcome }, 'gmail message processed');

      // Fire a silent push so the iOS app can attach the user's current GPS
      // to this transaction. Best-effort: never blocks the pipeline.
      if (outcome.kind === 'processed' && outcome.needsLocation) {
        void requestLocationFromAllDevices(outcome.transactionId).catch((err) =>
          app.log.error({ err, txId: outcome.transactionId }, 'APNs location request failed'),
        );
      }
    }

    if (latestHistoryId) await persistLatestHistoryId(latestHistoryId);
  }
}
