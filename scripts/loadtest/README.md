# Flexiyo load test

Simulates a compressed day of Flexiyo traffic and projects the measured usage
against the Cloudflare Workers **Free** plan limits, so you can see which cap
bites first and roughly how many daily active users each cap supports.

It drives the real API — no mocks: it signs up synthetic accounts, registers
devices, creates and accepts conversations, opens inbox + chat WebSockets,
sends messages with typing indicators, acknowledges delivery, reads chats, and
(optionally) fires the scheduled handler.

```
bun run dev                 # terminal 1 (leave running)
bun run loadtest            # terminal 2: 50 users/day, default scenario
bun run loadtest --users 200 --messages 30
bun run loadtest --reuse    # repeat with the same accounts (no new signups)
bun run loadtest --help     # all options
```

Output is a printable report plus a JSON file under `scripts/loadtest/results/`.

## What one "user-day" is

| Step | Per user-day |
|---|---|
| `GET /api/auth/me` (session check) | 1 |
| `GET /api/conversations?scope=all` (inbox seed) | 1 |
| Inbox WebSocket | 1 connection |
| Chat WebSockets for the day's conversations | `--chats` (default 3) connections |
| Message history per opened chat | `--chats` |
| Messages sent (`send_message` over WS, each acked) | `--messages` (default 20) |
| Typing frames (`typing_start` + `typing_stop`) | 2 × messages |
| Delivery acks from the receiving socket | messages that land on an open peer socket |
| Read receipts (`POST /:id/read`) | `--chats` |
| Heartbeats (`{"type":"ping"}`, answered by the DO runtime) | `--heartbeats` (default 4) |

All users run their day concurrently, so the run's totals **are** the daily
totals for `--users` daily active users. Wall-clock time is not simulated: a
compressed day for 50 users takes tens of seconds locally.

Message payloads are random 128-byte ciphertexts (incompressible), and every
recipient device gets a payload, matching what the Signal layer sends.

## What is measured vs. modeled

Measured by the client:

- HTTP requests, WebSocket connections, frames and bytes in both directions.
- `send_message` / read / history latency.
- Messages sent, messages that reached an open peer socket, delivery acks,
  read receipts, inbox events.
- Local D1 file growth (the SQLite file is checkpointed, then measured before
  seeding, after seeding, and after the run) plus row counts per table.
- Largest frame, for comparison with the 32 MiB DO WebSocket message cap.

Modeled in `costs.js` (client can't see server internals):

- Worker → Durable Object subrequests (`notifyInboxes`, read-receipt broadcast,
  conversation upserts), derived from `worker/src`.
- D1 rows read/written per operation, derived from the SQL each route runs.

Row reads are estimates: index scans on a large table can read more rows than
the estimate assumes. Row writes are deterministic for the modeled operations.
After a run against a deployed Worker you can check real numbers with
`bunx wrangler d1 insights flexiyo-db`.

## Reading the report

```
Free-plan projection at 50 users/day
free-plan limit        used at 50 users/day          cap   used              reaches cap at
─────────────────────  ────────────────────  ───────────  ─────  ──────────────────────────
DO requests — raw                     5,580      100,000   5.6%                ~896 users/day
DO requests — WS ÷ 20                 2,654      100,000   2.7%              ~1,884 users/day
...
```

- **DO requests — raw** counts every WebSocket connection, every incoming
  WebSocket frame, and every Worker → DO subrequest.
- **DO requests — WS ÷ 20** applies Cloudflare's billing ratio for incoming
  WebSocket messages (20 messages = 1 request). The docs don't say whether the
  Free daily cap uses the raw or the billed meter, so both are shown; the
  billed figure is the one that matches a paid invoice.
- **DO SQL limits** are listed as unused: `ChatRoom` keeps per-socket state in
  WebSocket attachments, not in DO SQLite. All relational SQL is D1.
- **D1 storage growth** comes from the local SQLite file and therefore includes
  page-granularity noise; it is most meaningful for larger `--users` runs.
- Free-tier D1 is **5M rows read/day**, not the 50M in the Paid plan. Override
  with `--rows-read-limit` if you want to project against a different tier.

## Notes and caveats

- **Seeding is one-time.** Account signup, device registration, conversation
  creation and acceptance are reported separately. If every one of the day's
  users is brand new, add that cost to the daily totals.
- **Auth rate limit.** The Worker limits register/login to 10-15 requests per
  minute per IP. The load test sends a unique synthetic `CF-Connecting-IP` per
  user (and retries 429s), which only works on localhost — hence the
  `--allow-remote` guard for non-local targets. Never point this at production.
- **Push notifications are not included.** `FCM_SERVICE_ACCOUNT` is unset
  locally, so no push or `push_tokens` read happens. In production one push
  attempt adds one D1 read per notification.
- **CPU time is not enforceable locally.** Wrangler does not apply the Free
  plan's 10 ms/request CPU limit, so the report cannot tell you whether PBKDF2
  hashing on register/login fits. Verify on a deployed Worker.
- **`--cron`** needs `bunx wrangler dev --test-scheduled`; without it the run
  prints a warning and continues.
- **`--reuse`** keeps accounts, tokens and conversations in
  `scripts/loadtest/.state.json` so repeated runs don't create new users. Delete
  the file (or drop `--reuse`) to start clean.

## Files

| File | Purpose |
|---|---|
| `index.js` | Orchestration: seeding, day phases, state, results |
| `client.js` | HTTP/WS client and metrics collector |
| `scenario.js` | Defaults, CLI parsing, usage text |
| `costs.js` | Modeled DO fan-out and D1 row costs |
| `limits.js` | Free-plan limits and sourcing notes |
| `report.js` | Projection table, verdict, local D1 measurement |
