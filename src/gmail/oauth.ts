// Gmail OAuth helpers — single-user V1.
//
// Flow (one-time setup):
//   1. Run `npx tsx scripts/gmail-auth.ts` → opens a browser to Google's consent screen
//   2. User approves; Google redirects back with a code
//   3. The script exchanges code → refresh_token, stores it in DB (GmailOauth row)
//
// At runtime: every API call gets an OAuth2Client primed with the stored refresh
// token. google-auth-library handles access-token refresh automatically.

import { OAuth2Client } from 'google-auth-library';
import { prisma } from '../db/client.js';

export const GMAIL_SCOPES = [
  'https://www.googleapis.com/auth/gmail.readonly',
  'https://www.googleapis.com/auth/gmail.metadata',
];

export interface OAuthEnv {
  clientId: string;
  clientSecret: string;
  redirectUri: string;
}

export function readOAuthEnv(): OAuthEnv {
  const clientId = process.env['GOOGLE_OAUTH_CLIENT_ID'];
  const clientSecret = process.env['GOOGLE_OAUTH_CLIENT_SECRET'];
  const redirectUri = process.env['GOOGLE_OAUTH_REDIRECT_URI'];
  if (!clientId || !clientSecret || !redirectUri) {
    throw new Error(
      'Missing GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET, or GOOGLE_OAUTH_REDIRECT_URI in env',
    );
  }
  return { clientId, clientSecret, redirectUri };
}

export function makeOAuthClient(env = readOAuthEnv()): OAuth2Client {
  return new OAuth2Client({
    clientId: env.clientId,
    clientSecret: env.clientSecret,
    redirectUri: env.redirectUri,
  });
}

export function authorizationUrl(client: OAuth2Client): string {
  return client.generateAuthUrl({
    access_type: 'offline',
    prompt: 'consent', // forces a refresh_token even on subsequent grants
    scope: GMAIL_SCOPES,
  });
}

export async function exchangeCodeForTokens(
  client: OAuth2Client,
  code: string,
): Promise<{ refreshToken: string; accessToken: string }> {
  const { tokens } = await client.getToken(code);
  if (!tokens.refresh_token) {
    throw new Error(
      'No refresh_token returned. Revoke prior consent at https://myaccount.google.com/permissions and retry.',
    );
  }
  if (!tokens.access_token) {
    throw new Error('No access_token returned.');
  }
  return {
    refreshToken: tokens.refresh_token,
    accessToken: tokens.access_token,
  };
}

// Persist (single-user) — overwrites any prior row.
export async function storeRefreshToken(refreshToken: string): Promise<void> {
  const existing = await prisma.gmailOauth.findFirst();
  if (existing) {
    await prisma.gmailOauth.update({
      where: { id: existing.id },
      data: { refreshToken },
    });
  } else {
    await prisma.gmailOauth.create({ data: { refreshToken } });
  }
}

export async function loadRefreshToken(): Promise<string | null> {
  const row = await prisma.gmailOauth.findFirst();
  return row?.refreshToken ?? null;
}

// For runtime use: returns an OAuth2Client primed with the stored refresh token.
export async function authorizedClient(): Promise<OAuth2Client> {
  const refreshToken = await loadRefreshToken();
  if (!refreshToken) {
    throw new Error('No Gmail refresh token in DB. Run scripts/gmail-auth.ts first.');
  }
  const client = makeOAuthClient();
  client.setCredentials({ refresh_token: refreshToken });
  return client;
}
