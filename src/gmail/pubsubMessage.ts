// Decode an incoming Pub/Sub push message into something useful.
//
// Pub/Sub push delivers a wrapped envelope:
//   { message: { data: <base64 JSON>, messageId, publishTime, attributes }, subscription }
//
// For Gmail, the inner JSON looks like:
//   { emailAddress: "user@gmail.com", historyId: "12345" }
//
// We pull both layers apart and validate with Zod so a malformed body fails fast.

import { z } from 'zod';

const pubsubEnvelopeSchema = z.object({
  message: z.object({
    data: z.string().min(1),
    messageId: z.string().optional(),
    publishTime: z.string().optional(),
    attributes: z.record(z.string()).optional(),
  }),
  subscription: z.string().optional(),
});

const gmailNotificationSchema = z.object({
  emailAddress: z.string().email(),
  historyId: z.union([z.string(), z.number()]).transform((v) => String(v)),
});

export interface GmailPushNotification {
  emailAddress: string;
  historyId: string;
  pubsubMessageId?: string;
  publishTime?: string;
}

export function decodeGmailPushBody(body: unknown): GmailPushNotification {
  const env = pubsubEnvelopeSchema.parse(body);
  const inner = JSON.parse(
    Buffer.from(env.message.data, 'base64').toString('utf-8'),
  ) as unknown;
  const notification = gmailNotificationSchema.parse(inner);
  return {
    emailAddress: notification.emailAddress,
    historyId: notification.historyId,
    ...(env.message.messageId !== undefined ? { pubsubMessageId: env.message.messageId } : {}),
    ...(env.message.publishTime !== undefined ? { publishTime: env.message.publishTime } : {}),
  };
}
