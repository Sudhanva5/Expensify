// HTML consent page for /authorize.
//
// Aesthetic: matches the Expensify iOS app's minimal-monochrome feel.
// One input (the static MCP_TOKEN as a password), one Approve button,
// one Deny link. No JavaScript — the form POSTs back to the same route.
// Server-rendered, no client framework, no external assets.

export interface ConsentParams {
  clientName: string;
  clientId: string;
  redirectUri: string;
  state: string | undefined;
  codeChallenge: string;
  codeChallengeMethod: string;
  scope: string | undefined;
  error?: string;
}

export function consentHtml(p: ConsentParams): string {
  // Encode each field once so we can drop them into hidden inputs without
  // worrying about quote-injection from the OAuth client. State is opaque
  // and arbitrary so this is especially important.
  const esc = htmlEscape;

  const errorBanner = p.error
    ? `<div class="error" role="alert">${esc(p.error)}</div>`
    : '';

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Connect to Expensify</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg:            light-dark(#fafaf7, #0e0e10);
      --surface:       light-dark(#ffffff, #1a1a1e);
      --text:          light-dark(#111114, #f3f3ef);
      --text-secondary: light-dark(#3a3a3f, #b5b5b0);
      --text-tertiary: light-dark(#75757a, #75757a);
      --hairline:      light-dark(#e6e6df, #2a2a2e);
      --accent:        light-dark(#4770e0, #7d9efa);
      --accent-text:   light-dark(#ffffff, #0e0e10);
      --error:         #d24545;
      --error-bg:      light-dark(#fdecec, #2a1414);
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; }
    body {
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif;
      font-size: 15px;
      line-height: 1.45;
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 24px;
    }
    main {
      width: 100%;
      max-width: 380px;
      background: var(--surface);
      border: 1px solid var(--hairline);
      border-radius: 14px;
      padding: 28px 24px;
    }
    h1 {
      font-size: 18px;
      font-weight: 600;
      letter-spacing: -0.01em;
      margin: 0 0 4px;
    }
    p.lede {
      font-size: 13px;
      color: var(--text-secondary);
      margin: 0 0 18px;
    }
    p.lede b { color: var(--text); font-weight: 600; }
    label {
      display: block;
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--text-tertiary);
      margin: 18px 0 6px;
    }
    input[type="password"] {
      width: 100%;
      padding: 10px 12px;
      font-size: 15px;
      font-family: ui-monospace, "SF Mono", Menlo, monospace;
      border: 1px solid var(--hairline);
      background: var(--bg);
      color: var(--text);
      border-radius: 8px;
      outline: none;
    }
    input[type="password"]:focus { border-color: var(--accent); }
    .meta {
      font-size: 12px;
      color: var(--text-tertiary);
      font-family: ui-monospace, "SF Mono", Menlo, monospace;
      word-break: break-all;
      margin-top: 8px;
    }
    .actions {
      margin-top: 22px;
      display: flex;
      gap: 10px;
      align-items: center;
    }
    button.approve {
      flex: 1;
      padding: 11px 14px;
      font-size: 14px;
      font-weight: 600;
      letter-spacing: -0.005em;
      background: var(--accent);
      color: var(--accent-text);
      border: none;
      border-radius: 8px;
      cursor: pointer;
    }
    a.deny {
      font-size: 13px;
      color: var(--text-tertiary);
      text-decoration: none;
    }
    a.deny:hover { color: var(--text-secondary); }
    .error {
      background: var(--error-bg);
      color: var(--error);
      border-radius: 8px;
      padding: 8px 10px;
      font-size: 13px;
      margin: 0 0 14px;
    }
    .scope {
      list-style: none;
      padding: 0;
      margin: 14px 0 0;
      font-size: 12px;
      color: var(--text-secondary);
    }
    .scope li::before {
      content: "→  ";
      color: var(--text-tertiary);
    }
  </style>
</head>
<body>
  <main>
    <h1>connect ${esc(p.clientName)} to expensify</h1>
    <p class="lede">paste your <b>MCP token</b> to approve read-only access to your transactions, budgets, and rules.</p>
    ${errorBanner}
    <form method="post" action="/authorize" autocomplete="off">
      <input type="hidden" name="client_id" value="${esc(p.clientId)}">
      <input type="hidden" name="redirect_uri" value="${esc(p.redirectUri)}">
      <input type="hidden" name="state" value="${esc(p.state ?? '')}">
      <input type="hidden" name="code_challenge" value="${esc(p.codeChallenge)}">
      <input type="hidden" name="code_challenge_method" value="${esc(p.codeChallengeMethod)}">
      <input type="hidden" name="scope" value="${esc(p.scope ?? '')}">
      <label for="mcp_token">mcp token</label>
      <input id="mcp_token" type="password" name="mcp_token" required autofocus
             placeholder="64-character hex string">
      <div class="actions">
        <button type="submit" class="approve">approve</button>
        <a class="deny" href="${esc(denyUrl(p.redirectUri, p.state))}">deny</a>
      </div>
    </form>
    <ul class="scope">
      <li>read your transactions, receipts, and categorizations</li>
      <li>read your budgets and alert history</li>
      <li>read your rules + learned merchant/VPA patterns</li>
      <li>${esc(p.clientName)} cannot edit, delete, or move money</li>
    </ul>
  </main>
</body>
</html>`;
}

function htmlEscape(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function denyUrl(redirectUri: string, state: string | undefined): string {
  const url = new URL(redirectUri);
  url.searchParams.set('error', 'access_denied');
  url.searchParams.set('error_description', 'The user denied the authorization request.');
  if (state) url.searchParams.set('state', state);
  return url.toString();
}
