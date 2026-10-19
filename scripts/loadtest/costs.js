/**
 * Server-side cost model for the load test.
 *
 * D1 rows: derived from the SQL each route runs (worker/src). Row-read numbers
 * are estimates because they depend on index scans and table size; treat them
 * as an order-of-magnitude check. Row-written counts are deterministic for the
 * operations below. Replace the estimates with measured values from
 * `bunx wrangler d1 insights flexiyo-db` after running against a deployed
 * account (see README).
 *
 * Durable Object requests: a client can only observe its own connections and
 * frames. Worker -> DO subrequests (`stub.fetch('/broadcast')`) are modeled
 * here from worker/src behaviour.
 */

/** Extra DO requests caused by each server-side operation (not observable by a client). */
export const DO_FANOUT = {
  // WS send_message persists in the ChatRoom object it arrived on and then
  // notifies both participants' inbox objects (services/inbox.js).
  sendMessage: 2,
  // Read receipt: conversation broadcast + the reader's inbox notify.
  readReceipt: 2,
  // New conversation: both participants' inboxes get an upsert.
  conversationCreate: 2,
  // Request accept/reject: conversation broadcast + 2 inbox upserts.
  requestDecision: 3,
};

export const D1 = {
  /** authMiddleware: token_revocations probe. Route SQL is counted per operation below. */
  authRequest(metrics, { extraReads = 0 } = {}) {
    metrics.count('d1.rowsRead', 1 + extraReads);
  },

  /** GET /api/auth/me: user row. */
  authMe(metrics) {
    metrics.count('d1.rowsRead', 1);
  },

  /** POST /api/auth/register: username lookup + user insert. */
  signup(metrics) {
    metrics.count('d1.rowsRead', 1);
    metrics.count('d1.rowsWritten', 1);
  },

  /** POST /api/auth/login: user lookup by username. */
  login(metrics) {
    metrics.count('d1.rowsRead', 1);
  },

  /** GET /api/conversations?scope=all: inbox + requests projections. */
  conversationsSeed(metrics, { returned }) {
    metrics.count('d1.rowsRead', 12 * returned + 6);
  },

  /** GET /api/conversations/:id/messages: message rows plus two delivery subqueries. */
  messageList(metrics, { returned }) {
    metrics.count('d1.rowsRead', 4 * returned + 2);
  },

  /** POST /api/conversations/:id/read: unread scan + delivery update. */
  readReceipt(metrics, { unread }) {
    metrics.count('d1.rowsRead', 6 + unread);
    metrics.count('d1.rowsWritten', unread);
  },

  /** WS send_message: gate probes, device set, then message + conversation + delivery writes. */
  wsSendMessage(metrics) {
    metrics.count('d1.rowsRead', 4);
    metrics.count('d1.rowsWritten', 3);
  },

  /** WS delivery_ack: message lookup + one delivery row stamped delivered. */
  deliveryAck(metrics) {
    metrics.count('d1.rowsRead', 3);
    metrics.count('d1.rowsWritten', 1);
  },

  /** WS upgrade: revocation probe, conversation membership, device row. */
  wsConnect(metrics, { chat }) {
    metrics.count('d1.rowsRead', chat ? 3 : 1);
  },

  /** POST /api/devices/register: device row + one-time pre-keys. */
  deviceRegister(metrics, { preKeys }) {
    metrics.count('d1.rowsRead', 1);
    metrics.count('d1.rowsWritten', 1 + preKeys);
  },

  /** POST /api/conversations + PATCH /:id/request. */
  conversationCreate(metrics) {
    metrics.count('d1.rowsRead', 3);
    metrics.count('d1.rowsWritten', 1);
  },

  requestDecision(metrics) {
    metrics.count('d1.rowsRead', 1);
    metrics.count('d1.rowsWritten', 1);
  },

  /** Hourly scheduled handler: meta read, expiry scan, media scan, meta upsert. */
  cron(metrics) {
    metrics.count('d1.rowsRead', 3);
    metrics.count('d1.rowsWritten', 1);
  },
};
