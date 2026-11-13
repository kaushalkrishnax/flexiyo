/**
 * Server-side cost model for the Flexiyo V2 load test.
 *
 * Models D1 row reads/writes for each route and WebSocket operation by
 * inspecting worker/src SQL. Row-read numbers are estimates: they depend on
 * index scans and table size, so treat them as order-of-magnitude. Row-write
 * counts are deterministic for the modeled operations. Replace the estimates
 * with measured values from `bunx wrangler d1 insights flexiyo-db` after
 * running against a deployed account (see scripts/loadtest/README.md).
 *
 * Two counters are kept:
 *   d1.rowsRead      — rows read from storage (index entries + table rows examined)
 *   d1.rowsReturned  — rows actually returned to the caller / client
 *
 * Scanned rows can far exceed returned rows when a query walks a range without
 * a supporting index (for example, a prefix LIKE over the whole users table
 * before 0015 added idx_users_username_nocase). That gap is the D1 read cost
 * this audit targets.
 *
 * Durable Object requests: a client can only observe its own connections and
 * frames. Worker -> DO subrequests (stub.fetch('/broadcast')) are modeled here
 * from worker/src behaviour and counted separately as do.fanout.
 */

/** Scenario presets. `history` is the assumed rows-per-conversation for the
 * cost model (the same-day load test itself builds fresh conversations, so
 * actual measured reads are small; the scenario columns project what reads
 * would be at larger scales). `unread` is the unread set a read pass touches.
 */
export const SCENARIOS = {
  normal: {
    label: 'normal',
    historyPerConversation: 50,
    unreadPerConversation: 3,
    messagesPerDay: 20,
    description: 'Typical day: short history, few unread per chat.',
  },
  highVolume: {
    label: 'high-volume',
    historyPerConversation: 500,
    unreadPerConversation: 10,
    messagesPerDay: 100,
    description: 'Busy day: moderate history, more unread, more messages.',
  },
  stress: {
    label: 'stress',
    historyPerConversation: 200_000,
    unreadPerConversation: 3,
    messagesPerDay: 20,
    description:
      'Pathological case: huge history, few unread. Reads should touch only ' +
      'the unread set, not the full history. Validates the sender_id = peerId ' +
      'rewrite and UPDATE ... RETURNING.',
  },
};

export function scenario(name) {
  return SCENARIOS[name] ?? SCENARIOS.normal;
}

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
  /** authMiddleware: token_revocations probe by jti (PK seek, 1 row). */
  authRequest(metrics, { scanned = 1, returned = 0 } = {}) {
    metrics.count('d1.rowsRead', scanned);
    metrics.count('d1.rowsReturned', returned);
  },

  /** GET /api/auth/me: users PK lookup. */
  authMe(metrics) {
    metrics.count('d1.rowsRead', 1);
    metrics.count('d1.rowsReturned', 1);
  },

  /** POST /api/auth/register: username unique-index seek + user insert. */
  signup(metrics) {
    metrics.count('d1.rowsRead', 1);
    metrics.count('d1.rowsReturned', 1);
    metrics.count('d1.rowsWritten', 1);
  },

  /** POST /api/auth/login: username unique-index seek. */
  login(metrics) {
    metrics.count('d1.rowsRead', 1);
    metrics.count('d1.rowsReturned', 1);
  },

  /**
   * GET /api/conversations?scope=all: conversation_user_state seek by user_id
   * (indexed) + per-conversation PK fetches + peer user lookups.
   * `returned` = conversations + requests projected.
   */
  conversationsSeed(metrics, { scanned, returned }) {
    metrics.count('d1.rowsRead', scanned ?? returned * 3 + 6);
    metrics.count('d1.rowsReturned', returned);
  },

  /** GET /api/conversations/:id/messages: message page via keyset index. */
  messageList(metrics, { scanned, returned }) {
    metrics.count('d1.rowsRead', scanned ?? returned * 2 + 2);
    metrics.count('d1.rowsReturned', returned);
  },

  /**
   * POST /api/conversations/:id/read: UPDATE ... RETURNING over the unread set
   * only (sender_id = peerId, read_at IS NULL). scanned ~= unread, returned = unread.
   */
  readReceipt(metrics, { unread }) {
    metrics.count('d1.rowsRead', unread);
    metrics.count('d1.rowsReturned', unread);
    metrics.count('d1.rowsWritten', unread + 1);
  },

  /** WS send_message: gate + coverage seeks (bounded) then message + state writes. */
  wsSendMessage(metrics) {
    metrics.count('d1.rowsRead', 7);
    metrics.count('d1.rowsReturned', 0);
    metrics.count('d1.rowsWritten', 5);
  },

  /** WS delivery_ack: message PK seek (1 row) + stamp delivered. */
  deliveryAck(metrics) {
    metrics.count('d1.rowsRead', 1);
    metrics.count('d1.rowsReturned', 1);
    metrics.count('d1.rowsWritten', 1);
  },

  /** WS upgrade: token_revocations probe + device active seek. */
  wsConnect(metrics) {
    metrics.count('d1.rowsRead', 2);
    metrics.count('d1.rowsReturned', 0);
  },

  /** POST /api/devices/v2/register: installation seek + active-device count + insert. */
  deviceRegister(metrics) {
    metrics.count('d1.rowsRead', 2);
    metrics.count('d1.rowsReturned', 1);
    metrics.count('d1.rowsWritten', 1);
  },

  /** POST /api/conversations: participant + existing-conv seeks + conv + 2 state rows. */
  conversationCreate(metrics) {
    metrics.count('d1.rowsRead', 3);
    metrics.count('d1.rowsReturned', 1);
    metrics.count('d1.rowsWritten', 4);
  },

  /** PATCH /api/conversations/:id/request: status update by conversation PK. */
  requestDecision(metrics) {
    metrics.count('d1.rowsRead', 1);
    metrics.count('d1.rowsWritten', 1);
  },

  /** GET /api/users/search?q=<prefix>: NOCASE index range seek; scanned ~= returned (+1). */
  usersSearch(metrics, { scanned, returned }) {
    metrics.count('d1.rowsRead', scanned ?? returned + 1);
    metrics.count('d1.rowsReturned', returned);
  },

  /** POST /api/conversations/:id/key-epochs: conversation + device + epoch seeks. */
  keyEpochs(metrics, { deviceCount = 2 } = {}) {
    metrics.count('d1.rowsRead', 5 + deviceCount);
    metrics.count('d1.rowsReturned', 1);
    metrics.count('d1.rowsWritten', deviceCount);
  },

  /** POST /api/conversations/:id/key-envelopes: per-recipient envelope upserts. */
  keyEnvelopes(metrics, { recipientCount = 2 } = {}) {
    metrics.count('d1.rowsRead', 4);
    metrics.count('d1.rowsReturned', 0);
    metrics.count('d1.rowsWritten', recipientCount);
  },

  /** Hourly scheduled handler: bounded expiry/media sweeps (LIMIT 1000). */
  cron(metrics, { scanned = 1000, written = 50 } = {}) {
    metrics.count('d1.rowsRead', scanned);
    metrics.count('d1.rowsWritten', written);
  },
};
