// OAuth storage layer. All DB access + crypto helpers live here so the
// route handlers stay focused on protocol shape (validate input → call
// store → format response).
//
// Design rules:
//   - Access tokens are NEVER persisted raw. We hash with sha256 and look
//     up by hash. The raw value is shown to the client exactly once at
//     /token exchange.
//   - Auth codes ARE stored raw — they're single-use and short-lived (60s),
//     and rotated immediately on consumption. Hashing them would just add
//     latency without changing the threat model.
//   - All clock operations use Date.now() so they're testable via fake
//     timers (no `new Date()` scattered around).

import crypto from 'node:crypto';
import { prisma } from '../../db/client.js';
import type { McpAccessToken, McpAuthCode, McpOAuthClient } from '@prisma/client';

/// 60s code lifetime. RFC 6749 §10.5 says auth codes SHOULD expire shortly
/// after issuance; the consensus pick is between 30s and 600s. 60 gives
/// claude.ai room for clock skew without leaving the code lying around.
const AUTH_CODE_TTL_MS = 60 * 1000;

export interface ClientRegistration {
  redirectUris: string[];
  clientName?: string;
  grantTypes?: string[];
  responseTypes?: string[];
  tokenEndpointAuthMethod?: string;
  scope?: string;
  rawMetadata: Record<string, unknown>;
}

export function generateClientId(): string {
  return crypto.randomBytes(16).toString('hex');
}

export function generateAuthCode(): string {
  return crypto.randomBytes(32).toString('base64url');
}

export function generateAccessToken(): string {
  return crypto.randomBytes(32).toString('hex');
}

export function hashToken(rawToken: string): string {
  return crypto.createHash('sha256').update(rawToken).digest('hex');
}

/// PKCE S256 verification, RFC 7636 §4.6.
/// challenge == base64url( sha256( verifier ) )
export function verifyPkceS256(codeVerifier: string, codeChallenge: string): boolean {
  const computed = crypto
    .createHash('sha256')
    .update(codeVerifier)
    .digest('base64url');
  return timingSafeEqualString(computed, codeChallenge);
}

function timingSafeEqualString(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

// ============================================================
// McpOAuthClient
// ============================================================

export async function registerClient(
  input: ClientRegistration,
): Promise<McpOAuthClient> {
  return prisma.mcpOAuthClient.create({
    data: {
      id: generateClientId(),
      clientName: input.clientName ?? null,
      redirectUris: input.redirectUris,
      grantTypes: input.grantTypes ?? ['authorization_code'],
      responseTypes: input.responseTypes ?? ['code'],
      tokenEndpointAuthMethod: input.tokenEndpointAuthMethod ?? 'none',
      scope: input.scope ?? null,
      metadata: input.rawMetadata as object,
    },
  });
}

export async function getClient(clientId: string): Promise<McpOAuthClient | null> {
  return prisma.mcpOAuthClient.findUnique({ where: { id: clientId } });
}

// ============================================================
// McpAuthCode
// ============================================================

export interface IssueCodeInput {
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
  codeChallengeMethod: string;
  scope?: string;
}

export async function issueAuthCode(input: IssueCodeInput): Promise<McpAuthCode> {
  return prisma.mcpAuthCode.create({
    data: {
      code: generateAuthCode(),
      clientId: input.clientId,
      redirectUri: input.redirectUri,
      codeChallenge: input.codeChallenge,
      codeChallengeMethod: input.codeChallengeMethod,
      scope: input.scope ?? null,
      expiresAt: new Date(Date.now() + AUTH_CODE_TTL_MS),
    },
  });
}

/// Atomically consume an auth code: mark it consumed and return the row
/// in a single round trip. If the code doesn't exist, is already
/// consumed, or has expired, returns null without mutating anything.
export async function consumeAuthCode(code: string): Promise<McpAuthCode | null> {
  const now = new Date();
  // UPDATE … RETURNING * via Prisma's updateMany doesn't return rows on
  // some versions; do it in a transaction so we get the row back AND a
  // single atomic mutation.
  return prisma.$transaction(async (tx) => {
    const row = await tx.mcpAuthCode.findUnique({ where: { code } });
    if (!row) return null;
    if (row.consumed) return null;
    if (row.expiresAt.getTime() <= now.getTime()) return null;
    await tx.mcpAuthCode.update({
      where: { code },
      data: { consumed: true },
    });
    return row;
  });
}

// ============================================================
// McpAccessToken
// ============================================================

export interface IssueTokenInput {
  clientId: string;
  scope?: string;
  label?: string;
  /// Optional explicit expiry. Null/undefined = never expires (revoke via
  /// the iOS Diagnostics admin endpoint).
  expiresAt?: Date | null;
}

/// Mint a new access token. Returns { raw, row } — the raw value is the
/// only chance to surface it; never recoverable from the DB after this.
export async function issueAccessToken(
  input: IssueTokenInput,
): Promise<{ raw: string; row: McpAccessToken }> {
  const raw = generateAccessToken();
  const row = await prisma.mcpAccessToken.create({
    data: {
      tokenHash: hashToken(raw),
      clientId: input.clientId,
      scope: input.scope ?? null,
      label: input.label ?? null,
      expiresAt: input.expiresAt ?? null,
    },
  });
  return { raw, row };
}

/// Verifies an incoming bearer string against the issued-token table.
/// Returns null when the token is unknown, expired, or revoked. Also
/// bumps lastUsedAt on success so the iOS Diagnostics view can show
/// recency without a separate audit log.
export async function lookupActiveToken(
  rawToken: string,
): Promise<{ token: McpAccessToken; clientName: string | null } | null> {
  const hash = hashToken(rawToken);
  const row = await prisma.mcpAccessToken.findUnique({
    where: { tokenHash: hash },
    include: { client: { select: { clientName: true } } },
  });
  if (!row) return null;
  if (row.revokedAt) return null;
  if (row.expiresAt && row.expiresAt.getTime() <= Date.now()) return null;

  // Bump lastUsedAt + parent client's lastUsedAt in parallel; both are
  // best-effort. Fire-and-forget so the hot path stays fast.
  void prisma.mcpAccessToken
    .update({
      where: { id: row.id },
      data: { lastUsedAt: new Date() },
    })
    .catch(() => undefined);
  void prisma.mcpOAuthClient
    .update({
      where: { id: row.clientId },
      data: { lastUsedAt: new Date() },
    })
    .catch(() => undefined);

  return { token: row, clientName: row.client.clientName };
}

export async function listIssuedTokens(): Promise<
  Array<McpAccessToken & { clientName: string | null }>
> {
  const rows = await prisma.mcpAccessToken.findMany({
    orderBy: { issuedAt: 'desc' },
    include: { client: { select: { clientName: true } } },
  });
  return rows.map((r) => ({
    ...r,
    clientName: r.client.clientName,
  }));
}

export async function revokeToken(id: string): Promise<boolean> {
  try {
    await prisma.mcpAccessToken.update({
      where: { id },
      data: { revokedAt: new Date() },
    });
    return true;
  } catch {
    return false;
  }
}
