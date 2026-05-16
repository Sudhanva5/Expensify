// One-off / cron-able: pull the user's Google contacts via People API
// and refresh the GoogleContact cache. Idempotent. Run after the user
// re-grants OAuth consent (the contacts.readonly scope was added to
// GMAIL_SCOPES — existing refresh tokens won't have it until consent
// is re-issued).
//
//   npx tsx scripts/google-contacts-sync.ts

import { authorizedClient } from '../src/gmail/oauth.js';
import { syncGoogleContacts } from '../src/services/googleContacts.js';

async function main() {
  const auth = await authorizedClient();
  const { fetched, saved } = await syncGoogleContacts(auth);
  console.log(`[google-contacts-sync] fetched=${fetched} saved=${saved}`);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error('[google-contacts-sync] failed:', err);
    process.exit(1);
  });
