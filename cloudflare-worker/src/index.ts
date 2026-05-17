/// Reverse-proxy Worker that fronts the Railway backend.
///
/// Why this exists: Jio's DPI started throttling
/// expensify.sudhanva.space at random times. Cloudflare's anycast IPs
/// for proxied custom domains are a known target. A Worker on
/// *.workers.dev (different IP pool, Host header is a shared
/// Cloudflare-platform name) is much harder for carrier filters to
/// single out — they can't block workers.dev without breaking a huge
/// fraction of the internet.
///
/// What the Worker does: takes any inbound request, rewrites the URL
/// to point at the Railway origin, replays method/headers/body, and
/// streams the response back. iOS only needs to flip Constants.baseURL
/// from "expensify.sudhanva.space" → "<name>.<account>.workers.dev".
///
/// Pub/Sub webhook safety: the GET /webhooks/gmail path is also
/// protected by an audience-validated JWT, so even if the Worker URL
/// leaks it can't be used to spoof Gmail pushes.
///
/// Tier: free plan covers 100k requests/day — orders of magnitude
/// above what one iPhone polling every few minutes will use.

const ORIGIN = 'https://expensify-production.up.railway.app';

export default {
  async fetch(request: Request): Promise<Response> {
    const inbound = new URL(request.url);
    const target = new URL(inbound.pathname + inbound.search, ORIGIN);

    // Clone request preserving everything except the URL. We also drop
    // any Cloudflare-injected headers that would confuse the Fastify
    // origin (Cf-Connecting-Ip etc. stay — those help debugging).
    const headers = new Headers(request.headers);
    headers.set('Host', target.host);
    // Origin/Referer aren't meaningful after a reverse-proxy hop;
    // strip them so the backend doesn't reject CORS-shaped requests.
    headers.delete('Origin');
    headers.delete('Referer');

    const proxied = new Request(target.toString(), {
      method: request.method,
      headers,
      body: request.body,
      redirect: 'manual',
    });

    return fetch(proxied);
  },
};
