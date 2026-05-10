import { describe, it, expect } from 'vitest';
import { decodeGmailPushBody } from '../../src/gmail/pubsubMessage.js';

function pubsubEnvelope(inner: object, extra: object = {}): unknown {
  return {
    message: {
      data: Buffer.from(JSON.stringify(inner)).toString('base64'),
      messageId: 'pubsub-msg-123',
      publishTime: '2026-05-10T12:00:00Z',
      ...extra,
    },
    subscription: 'projects/test/subscriptions/gmail-sub',
  };
}

describe('decodeGmailPushBody', () => {
  it('decodes a well-formed Gmail push notification', () => {
    const body = pubsubEnvelope({
      emailAddress: 'sm.acharya@scaler.com',
      historyId: '123456',
    });
    const out = decodeGmailPushBody(body);

    expect(out.emailAddress).toBe('sm.acharya@scaler.com');
    expect(out.historyId).toBe('123456');
    expect(out.pubsubMessageId).toBe('pubsub-msg-123');
  });

  it('coerces numeric historyId to string', () => {
    const body = pubsubEnvelope({
      emailAddress: 'a@b.com',
      historyId: 999,
    });
    const out = decodeGmailPushBody(body);
    expect(out.historyId).toBe('999');
  });

  it('throws on invalid email', () => {
    const body = pubsubEnvelope({
      emailAddress: 'not-an-email',
      historyId: '1',
    });
    expect(() => decodeGmailPushBody(body)).toThrow();
  });

  it('throws on missing message field', () => {
    expect(() => decodeGmailPushBody({})).toThrow();
  });

  it('throws on garbage base64 payload', () => {
    const body = {
      message: { data: 'not-valid-base64-json!!' },
    };
    expect(() => decodeGmailPushBody(body)).toThrow();
  });
});
