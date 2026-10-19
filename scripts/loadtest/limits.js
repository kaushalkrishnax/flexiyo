/**
 * Cloudflare Workers Free plan limits, as published in the docs (Oct 2026).
 * The load test projects measured usage against these numbers.
 */

export const LIMITS = {
  durableObjects: {
    classes: 100,
    objects: Infinity,
    storageGbPerAccount: 5,
    storageGbPerObject: 1,
    requestsPerDay: 100_000,
    computeGbSecondsPerDay: 13_000,
    cpuSecondsPerRequest: 30,
    wsMessageMiB: 32,
    /** Billing-only ratio for incoming WebSocket messages (docs, pricing footnote 2). */
    wsMessageBillingRatio: 20,
    source: 'https://developers.cloudflare.com/durable-objects/platform/pricing/',
    limitsSource: 'https://developers.cloudflare.com/durable-objects/platform/limits/',
  },
  d1: {
    rowsReadPerDay: 5_000_000,
    rowsWrittenPerDay: 100_000,
    storageGb: 5,
    source: 'https://developers.cloudflare.com/d1/platform/pricing/',
  },
  workers: {
    requestsPerDay: 100_000,
    cpuMsPerRequest: 10,
    source: 'https://developers.cloudflare.com/workers/platform/limits/',
  },
};

export const LIMIT_NOTES = [
  'Messages sent can exceed messages pushed to an open peer chat socket: a recipient only keeps the chats they opened that day connected, so the rest arrive as inbox events (unread badge) and their history/read traffic happens when the chat is opened later. DO request cost is the same either way — the recipient\'s inbox Durable Object is notified for every message.',
  'D1 row reads are modeled from the SQL each route runs; index scans on a large table can read more rows than the estimate assumes. Row writes are deterministic for the modeled operations. Confirm on a deployed Worker with `bunx wrangler d1 insights flexiyo-db`.',
  'Push notifications are excluded: FCM_SERVICE_ACCOUNT is unset locally, so push attempts never reach the push_tokens query. In production each send attempt adds one D1 read per notification.',
  'Cloudflare bills incoming WebSocket messages at a 20:1 ratio (pricing footnote 2); outgoing messages and auto-response pings are free. The docs do not state whether the Free daily request cap uses the raw or the billing-adjusted meter, so both are shown.',
  'The Free plan limit page lists 5 million SQL rows read/day (D1 and SQLite-backed Durable Objects alike). 50 million is the Paid-plan included allocation, so the 5M figure is used unless --rows-read-limit overrides it.',
  'Flexiyo stores no data in Durable Object SQLite: ChatRoom keeps per-socket state in WebSocket attachments, so the DO SQL row/storage limits are never consumed. All relational SQL runs against D1.',
  'Workers Free CPU time is 10 ms per request (the 30 s figure is the DO per-invocation cap). PBKDF2 login/register hashing is the most likely CPU-bound route; local wrangler does not enforce the cap, so confirm on a deployed Worker.',
];
