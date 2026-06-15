// OAuth 2.1 endpoints for claude.ai web's custom-connector flow.
//
// Routes installed at the MCP server root:
//   GET  /.well-known/oauth-authorization-server   — RFC 8414 metadata
//   GET  /.well-known/oauth-protected-resource     — RFC 9728 metadata
//   POST /register                                  — RFC 7591 dynamic client registration
//   GET  /authorize                                 — render consent HTML
//   POST /authorize                                 — process consent form, redirect with code
//   POST /token                                     — exchange code for access token (PKCE)
//
// Public clients only (token_endpoint_auth_method = "none"), PKCE-S256
// required. The "user password" on the consent screen is the existing
// static MCP_TOKEN env var — same secret that already gates Claude
// Code / Claude Desktop, so there's exactly one thing to rotate.
//
// No refresh tokens yet — access tokens don't expire; iOS Diagnostics
// is the revoke surface. Refresh-token support is a future addition
// (just an extra column on McpAccessToken + a /token grant_type branch).

import type { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { consentHtml } from './consent.js';
import {
  consumeAuthCode,
  getClient,
  issueAccessToken,
  issueAuthCode,
  registerClient,
  verifyPkceS256,
} from './store.js';

interface AuthorizeQuery {
  response_type?: string;
  client_id?: string;
  redirect_uri?: string;
  code_challenge?: string;
  code_challenge_method?: string;
  state?: string;
  scope?: string;
}

interface AuthorizePostBody {
  client_id?: string;
  redirect_uri?: string;
  code_challenge?: string;
  code_challenge_method?: string;
  state?: string;
  scope?: string;
  mcp_token?: string;
}

interface RegisterBody {
  redirect_uris?: string[];
  client_name?: string;
  grant_types?: string[];
  response_types?: string[];
  token_endpoint_auth_method?: string;
  scope?: string;
  [key: string]: unknown;
}

interface TokenBody {
  grant_type?: string;
  code?: string;
  code_verifier?: string;
  client_id?: string;
  redirect_uri?: string;
}

export async function oauthRoutes(app: FastifyInstance): Promise<void> {
  // Public URL the MCP server reachable on. Used to build absolute URLs in
  // metadata responses. Falls back to the request host if not configured —
  // fine for local dev, but in production we set MCP_PUBLIC_URL so the
  // metadata is stable.
  const publicUrlFromEnv = process.env['MCP_PUBLIC_URL'];

  const issuerOf = (req: FastifyRequest): string => {
    if (publicUrlFromEnv) return publicUrlFromEnv.replace(/\/$/, '');
    // Reconstruct from request. Trust X-Forwarded-Proto (Railway sets it)
    // so we don't return http:// behind the TLS-terminating proxy.
    const proto = (req.headers['x-forwarded-proto'] as string) || 'https';
    const host = req.headers['host'] as string;
    return `${proto}://${host}`;
  };

  app.register(async (instance) => {
    instance.addContentTypeParser(
      'application/x-www-form-urlencoded',
      { parseAs: 'string' },
      (_req, body, done) => {
        try {
          const params = new URLSearchParams(body as string);
          const out: Record<string, string> = {};
          for (const [k, v] of params) out[k] = v;
          done(null, out);
        } catch (err) {
          done(err as Error, undefined);
        }
      },
    );

    // ============================================================
    // /.well-known/oauth-authorization-server
    // ============================================================
    instance.get('/.well-known/oauth-authorization-server', async (req, reply) => {
      const issuer = issuerOf(req);
      reply.header('cache-control', 'public, max-age=3600');
      return {
        issuer,
        authorization_endpoint: `${issuer}/authorize`,
        token_endpoint: `${issuer}/token`,
        registration_endpoint: `${issuer}/register`,
        response_types_supported: ['code'],
        grant_types_supported: ['authorization_code'],
        code_challenge_methods_supported: ['S256'],
        token_endpoint_auth_methods_supported: ['none'],
        scopes_supported: ['mcp'],
      };
    });

    // ============================================================
    // /.well-known/oauth-protected-resource[/mcp]
    // Some discovery flows hit the bare path, others append the resource
    // path. Serve both.
    // ============================================================
    const protectedResource = (req: FastifyRequest) => {
      const issuer = issuerOf(req);
      return {
        resource: `${issuer}/mcp`,
        authorization_servers: [issuer],
        scopes_supported: ['mcp'],
        bearer_methods_supported: ['header'],
      };
    };
    instance.get('/.well-known/oauth-protected-resource', async (req, reply) => {
      reply.header('cache-control', 'public, max-age=3600');
      return protectedResource(req);
    });
    instance.get('/.well-known/oauth-protected-resource/mcp', async (req, reply) => {
      reply.header('cache-control', 'public, max-age=3600');
      return protectedResource(req);
    });

    // ============================================================
    // POST /register — dynamic client registration (RFC 7591)
    // ============================================================
    instance.post('/register', async (req, reply) => {
      const body = (req.body ?? {}) as RegisterBody;
      if (!Array.isArray(body.redirect_uris) || body.redirect_uris.length === 0) {
        reply.code(400);
        return {
          error: 'invalid_client_metadata',
          error_description: 'redirect_uris must be a non-empty array',
        };
      }

      // Permit https URIs unconditionally and http://localhost / 127.0.0.1
      // for local dev. Reject everything else (including http://other-host)
      // — that's the loose-redirect class of OAuth bugs.
      for (const uri of body.redirect_uris) {
        if (typeof uri !== 'string') {
          reply.code(400);
          return {
            error: 'invalid_redirect_uri',
            error_description: 'redirect_uris must be strings',
          };
        }
        try {
          const u = new URL(uri);
          const okHttp =
            u.protocol === 'http:' &&
            (u.hostname === 'localhost' || u.hostname === '127.0.0.1');
          if (u.protocol !== 'https:' && !okHttp) {
            reply.code(400);
            return {
              error: 'invalid_redirect_uri',
              error_description: `redirect_uri must use https (or http://localhost): ${uri}`,
            };
          }
        } catch {
          reply.code(400);
          return {
            error: 'invalid_redirect_uri',
            error_description: `redirect_uri is not a valid URL: ${uri}`,
          };
        }
      }

      const created = await registerClient({
        redirectUris: body.redirect_uris,
        clientName: body.client_name,
        grantTypes: body.grant_types,
        responseTypes: body.response_types,
        tokenEndpointAuthMethod: body.token_endpoint_auth_method,
        scope: body.scope,
        rawMetadata: body as Record<string, unknown>,
      });

      reply.code(201);
      return {
        client_id: created.id,
        client_id_issued_at: Math.floor(created.createdAt.getTime() / 1000),
        redirect_uris: created.redirectUris,
        client_name: created.clientName ?? undefined,
        grant_types: created.grantTypes,
        response_types: created.responseTypes,
        token_endpoint_auth_method: created.tokenEndpointAuthMethod,
        scope: created.scope ?? undefined,
      };
    });

    // ============================================================
    // GET /authorize — render consent page
    // ============================================================
    instance.get<{ Querystring: AuthorizeQuery }>('/authorize', async (req, reply) => {
      const q = req.query;
      const failureReason = await validateAuthorizeParams(q);
      if (failureReason) {
        reply.code(400).type('text/plain');
        return failureReason;
      }

      const client = await getClient(q.client_id!);
      if (!client) {
        reply.code(400).type('text/plain');
        return 'invalid_client: unknown client_id';
      }
      if (!client.redirectUris.includes(q.redirect_uri!)) {
        reply.code(400).type('text/plain');
        return 'invalid_redirect_uri: not registered for this client';
      }

      reply.type('text/html').header('cache-control', 'no-store');
      return consentHtml({
        clientName: client.clientName?.trim() || 'this client',
        clientId: q.client_id!,
        redirectUri: q.redirect_uri!,
        state: q.state,
        codeChallenge: q.code_challenge!,
        codeChallengeMethod: q.code_challenge_method!,
        scope: q.scope,
      });
    });

    // ============================================================
    // POST /authorize — process consent form
    // ============================================================
    instance.post<{ Body: AuthorizePostBody }>('/authorize', async (req, reply) => {
      const b = req.body ?? {};
      const failureReason = await validateAuthorizeParams({
        response_type: 'code',
        client_id: b.client_id,
        redirect_uri: b.redirect_uri,
        code_challenge: b.code_challenge,
        code_challenge_method: b.code_challenge_method,
        state: b.state,
        scope: b.scope,
      });
      if (failureReason) {
        reply.code(400).type('text/plain');
        return failureReason;
      }

      const client = await getClient(b.client_id!);
      if (!client || !client.redirectUris.includes(b.redirect_uri!)) {
        reply.code(400).type('text/plain');
        return 'invalid_redirect_uri';
      }

      const expectedToken = process.env['MCP_TOKEN'];
      if (!expectedToken) {
        reply.code(500).type('text/plain');
        return 'MCP_TOKEN not configured on server';
      }

      // Wrong password → re-render the form with an error banner instead of
      // redirecting to the client. Keeps the user in our page so they can
      // retry without round-tripping through claude.ai.
      if (!b.mcp_token || b.mcp_token.trim() !== expectedToken) {
        reply.code(401).type('text/html').header('cache-control', 'no-store');
        return consentHtml({
          clientName: client.clientName?.trim() || 'this client',
          clientId: b.client_id!,
          redirectUri: b.redirect_uri!,
          state: b.state,
          codeChallenge: b.code_challenge!,
          codeChallengeMethod: b.code_challenge_method!,
          scope: b.scope,
          error: "that token didn't match. try again.",
        });
      }

      const code = await issueAuthCode({
        clientId: client.id,
        redirectUri: b.redirect_uri!,
        codeChallenge: b.code_challenge!,
        codeChallengeMethod: b.code_challenge_method!,
        scope: b.scope,
      });

      const redirect = new URL(b.redirect_uri!);
      redirect.searchParams.set('code', code.code);
      if (b.state) redirect.searchParams.set('state', b.state);
      reply.code(302).header('location', redirect.toString());
      return null;
    });

    // ============================================================
    // POST /token — authorization-code exchange
    // ============================================================
    instance.post<{ Body: TokenBody }>('/token', async (req, reply) => {
      const b = req.body ?? {};
      if (b.grant_type !== 'authorization_code') {
        reply.code(400);
        return { error: 'unsupported_grant_type' };
      }
      if (!b.code || !b.code_verifier || !b.client_id || !b.redirect_uri) {
        reply.code(400);
        return {
          error: 'invalid_request',
          error_description: 'code, code_verifier, client_id, redirect_uri required',
        };
      }

      const client = await getClient(b.client_id);
      if (!client) {
        reply.code(401);
        return { error: 'invalid_client' };
      }

      const code = await consumeAuthCode(b.code);
      if (!code) {
        reply.code(400);
        return { error: 'invalid_grant', error_description: 'code unknown, expired, or already used' };
      }
      if (code.clientId !== client.id) {
        reply.code(400);
        return { error: 'invalid_grant', error_description: 'code was issued to a different client' };
      }
      if (code.redirectUri !== b.redirect_uri) {
        reply.code(400);
        return { error: 'invalid_grant', error_description: 'redirect_uri mismatch' };
      }
      if (!verifyPkceS256(b.code_verifier, code.codeChallenge)) {
        reply.code(400);
        return { error: 'invalid_grant', error_description: 'PKCE verification failed' };
      }

      const { raw } = await issueAccessToken({
        clientId: client.id,
        scope: code.scope ?? undefined,
        label: client.clientName ?? undefined,
      });

      reply.header('cache-control', 'no-store').header('pragma', 'no-cache');
      return {
        access_token: raw,
        token_type: 'Bearer',
        scope: code.scope ?? undefined,
      };
    });
  });
}

async function validateAuthorizeParams(q: AuthorizeQuery): Promise<string | null> {
  if (q.response_type !== 'code') return 'unsupported_response_type: must be "code"';
  if (!q.client_id) return 'invalid_request: client_id required';
  if (!q.redirect_uri) return 'invalid_request: redirect_uri required';
  if (!q.code_challenge) return 'invalid_request: code_challenge required (PKCE)';
  if (q.code_challenge_method !== 'S256') {
    return 'invalid_request: code_challenge_method must be S256';
  }
  return null;
}
