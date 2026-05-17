# expensify-proxy (Cloudflare Worker)

A 20-line reverse proxy that fronts the Railway backend.

## Why

Jio's DPI started throttling `expensify.sudhanva.space` at random
times. The custom domain on Cloudflare is still served from a small
pool of anycast IPs that carrier filters can target. Workers run on a
different IP pool, and the inbound `Host` header is a shared
`*.workers.dev` name — much harder for Jio to single out without
breaking a huge chunk of the public internet.

## Deploy

```bash
cd cloudflare-worker
npm install
npx wrangler login           # one-time, opens browser to your CF account
npx wrangler deploy          # builds + uploads; prints the final URL
```

The deploy step prints something like:

```
Total Upload: 1.20 KiB / gzip: 0.55 KiB
Worker Startup Time: 1 ms
Uploaded expensify-proxy (0.42 sec)
Deployed expensify-proxy triggers (0.32 sec)
  https://expensify-proxy.<your-account>.workers.dev
```

Copy that URL.

## Wire it up on iOS

Edit `Expensify/Expensify/Constants.swift`:

```swift
// Before
static let baseURL: URL = URL(string: "https://expensify.sudhanva.space")!

// After
static let baseURL: URL = URL(string: "https://expensify-proxy.<your-account>.workers.dev")!
```

Rebuild + reinstall the iOS app. The Worker is fully transparent — every
endpoint (auth, transactions, devices, contacts, rules) keeps working
because requests are replayed verbatim against the Railway origin.

## Tail logs

```bash
npx wrangler tail
```

## Free-tier limits

- 100,000 requests / day
- 10ms CPU per request

A reverse proxy uses well under 1ms of CPU. One iPhone polling every
few minutes is nowhere near 100k/day.
