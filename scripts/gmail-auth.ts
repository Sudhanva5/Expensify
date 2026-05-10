// One-time OAuth flow to authorize the app against your Gmail account.
//
// Prereqs (in your Google Cloud project, see CLAUDE.md "Gmail Setup"):
//   1. OAuth client ID created (type: Web app)
//   2. Authorized redirect URI: http://127.0.0.1:5176/oauth2callback
//   3. Test user added: your Gmail address
//   4. .env contains GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET,
//      GOOGLE_OAUTH_REDIRECT_URI=http://127.0.0.1:5176/oauth2callback
//
// Run: npx tsx scripts/gmail-auth.ts
// Opens your browser → Google consent → redirects back → script stores refresh
// token in DB and exits.

import { createServer } from 'node:http';
import { URL } from 'node:url';
import {
  authorizationUrl,
  exchangeCodeForTokens,
  makeOAuthClient,
  storeRefreshToken,
} from '../src/gmail/oauth.js';
import { prisma } from '../src/db/client.js';

async function main() {
  const client = makeOAuthClient();
  const url = authorizationUrl(client);

  const port = new URL(process.env['GOOGLE_OAUTH_REDIRECT_URI'] ?? '').port || '5176';

  console.log('\n→ Open this URL in your browser to authorize:\n');
  console.log(url);
  console.log(`\nWaiting for redirect on http://127.0.0.1:${port}/oauth2callback ...\n`);

  await new Promise<void>((resolve, reject) => {
    const server = createServer(async (req, res) => {
      try {
        const reqUrl = new URL(req.url!, `http://localhost:${port}`);
        if (reqUrl.pathname !== '/oauth2callback') {
          res.writeHead(404).end();
          return;
        }
        const code = reqUrl.searchParams.get('code');
        const error = reqUrl.searchParams.get('error');
        if (error) {
          res.writeHead(400, { 'Content-Type': 'text/plain' });
          res.end(`OAuth error: ${error}`);
          server.close();
          reject(new Error(`OAuth denied: ${error}`));
          return;
        }
        if (!code) {
          res.writeHead(400).end('Missing code');
          return;
        }
        const tokens = await exchangeCodeForTokens(client, code);
        await storeRefreshToken(tokens.refreshToken);
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(
          '<h2>Authorized.</h2><p>Refresh token stored. You can close this tab.</p>',
        );
        server.close();
        resolve();
      } catch (err) {
        res.writeHead(500).end('Internal error');
        server.close();
        reject(err as Error);
      }
    });
    server.listen(Number(port));
  });

  console.log('\n✓ Refresh token stored in DB (table: GmailOauth).');
  console.log('Next: register the Gmail watch — see scripts/gmail-watch.ts.');
  await prisma.$disconnect();
}

main().catch(async (err) => {
  console.error(err);
  await prisma.$disconnect();
  process.exit(1);
});
