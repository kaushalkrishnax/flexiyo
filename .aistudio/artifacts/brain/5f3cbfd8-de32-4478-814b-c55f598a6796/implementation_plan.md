# Flexiyo V2-Only Messaging & D1 Read Optimization Plan

Flexiyo will standardize exclusively on V2 conversation-key end-to-end encryption across the Cloudflare Worker backend, D1 schema, and Flutter client while eliminating full-history message and delivery-table scans in inbox and conversation queries through incrementally maintained per-user conversation state.

## User Review & Critical Decisions

> [!IMPORTANT]
> The following architectural and workflow decisions were confirmed during planning and govern the implementation below.

- **Confirmed Decision 1 (V1 Data Migration)**: Forward-only D1 migration will permanently delete legacy `encryption_version = 1` messages and V1-only device registrations while preserving all V2 messages, key epochs, wrapped device key envelopes, V2 devices, conversations, and users.
- **Confirmed Decision 2 (Complete Signal Removal)**: Both the temporary V1-to-V2 device upgrade endpoint and the Flutter Signal Protocol dependency (`libsignal_protocol_dart`) plus all Signal session stores and key-bundle code will be removed completely.
- **Confirmed Decision 3 (Verification & Repository Hand-off)**: Because `.git`, `gh`, `flutter`, `dart`, and global `wrangler` are unavailable in this execution container, all code and migration edits plus Worker TypeScript checks, Vitest suites, local SQLite/D1 migration validation, and `EXPLAIN QUERY PLAN` verification will be executed here, and exact git/PR and Flutter verification commands will be summarized at completion.
- **Key Schema Choice (Recommended Default)**: Drop V1-only columns (`encryption_version` and Signal bundle columns) from D1 tables rather than keeping nullable placeholders, while continuing to expose `encryptionVersion: 2` in HTTP/WebSocket JSON payloads and enforcing `encryptionVersion === 2` in request validation so client-server protocol contracts remain explicit and non-breaking.

---

## 1. Overview & Core Concept

- **What It Does**: Unifies all messaging, device registration, QR pairing, media, and read/delivery receipts around V2 conversation-key encryption, and replaces O(history) inbox SQL aggregations with O(conversations) indexed lookups backed by per-user state counters.
- **Target Audience / Persona**: Flexiyo mobile/web users opening their inbox, message requests, and chat threads, plus operators managing D1 row-read quotas under growing message histories.
- **Key Value**: Removes dual-protocol complexity and Signal key-bundle surface area while cutting D1 row reads on inbox refreshes from scanning historical messages and per-device delivery rows down to reading two compact rows per visible conversation.

---

## 2. User Experience & Behavioral Continuity

Because this is an architectural standardization and database read-path refactor rather than a visual redesign, existing V2 user flows remain seamless while eliminating legacy edge cases:

- **Inbox & Message Requests**: Loading the inbox, message requests, or blocked-user lists renders peer metadata, request acceptance state, unread counts, peer-seen receipts, and last-message direction (`lastMessageIsMine`) with identical API semantics—now served in a single query for `scope=all` and without historical message scans.
- **Message Request Previews**: Message requests decrypt their latest V2 ciphertext preview using the conversation-key crypto layer rather than Signal sessions.
- **Device Registration & QR Pairing**: First-device onboarding registers an X25519 identity key directly via V2 device registration; secondary devices join and receive wrapped conversation keys via QR pairing. Previously linked devices remain usable, and revoked or mismatched installations surface clear re-login/pairing errors instead of attempting legacy Signal upgrades.
- **Read Receipts & Disappearing Messages**: Opening a thread clears the reader's unread count, advances `last_read_at`, updates the sender's `peer_seen_at`, and honors disappearing timers (including burn-after-read `-1` deletion and timed expiry) while keeping inbox state synchronized.
- **Local Client Storage Continuity**: Upgrading the local client database drops the obsolete Signal session cache and purges any leftover non-V2 local rows without disrupting active V2 threads or secure key envelopes.

---

## 3. Key Product Decisions & Trade-Offs

- **Decision 1: Materialized Per-User State (`conversation_user_state`) Over Index-Only Tuning**
  - *Chosen Approach*: Introduce a compact `(conversation_id, user_id)` state table storing `unread_count`, `last_read_at`, and `peer_seen_at`, paired with `last_message_sender_id` alongside `last_message_at` on `conversations`.
  - *Why*: Index tuning alone still forces D1 to visit historical message rows for `COUNT(...)` and `MAX(read_at)` per conversation on every inbox poll. Storing counters incrementally reduces inbox complexity from O(total messages) to O(user's active conversations).
  - *Alternatives Considered*: Partial indexes on `messages` (already added previously, still scales poorly with long chats) or KV/Durable Object inbox caches (adds eventual-consistency drift outside D1 transactions).

- **Decision 2: Purge V1 Rows & Drop Legacy Tables/Columns in Forward-Only Migration**
  - *Chosen Approach*: Delete `encryption_version != 2` messages and devices, drop `message_deliveries` and `pre_keys`, remove obsolete scan indexes, and drop Signal/version columns via `ALTER TABLE ... DROP COLUMN`, then backfill `conversations` and `conversation_user_state` from remaining V2 history.
  - *Why*: Eliminating `message_deliveries` and `pre_keys` completely removes fan-out writes, dual-branch conditional logic, and dead storage while keeping all prior migrations untouched.
  - *Alternatives Considered*: Keeping `encryption_version` columns or `message_deliveries` as tombstones, which preserves schema clutter and invites accidental fallback queries.

- **Decision 3: Bounded Scoped Recompute on Destructive Message Operations**
  - *Chosen Approach*: Maintain counters purely incrementally on send and read (`+1` / reset to `0`), and perform scoped recomputation only inside message deletion/unsend/expiry batches (decrementing deleted unread counts via a pre-delete `GROUP BY sender_id` query and recomputing `last_message_at`, `last_message_sender_id`, and `peer_seen_at` only when a deleted message affected latest or read state).
  - *Why*: Sends and reads represent the overwhelming majority of traffic and require zero historical scans; deletions are rare and stay bounded to a single conversation using a targeted partial index.
  - *Alternatives Considered*: Triggering full recomputation on every read or cron sweep, which reintroduces unnecessary row reads.

- **Decision 4: Single-Query `scope=all` Inbox Execution**
  - *Chosen Approach*: Serve `scope=all` (`inbox` + `requests`) from a single `conversation_user_state`-driven query partitioned in memory rather than executing the list query twice.
  - *Why*: Halves D1 row reads for clients fetching both tabs simultaneously.
  - *Alternatives Considered*: Separate parallel queries for inbox and requests, which doubles repeated joins against state and peer rows.

---

## 4. Technical Architecture & Data Strategy

### Architecture & Component Diagram

```text
┌───────────────────────────┐        ┌──────────────────────────────────────┐
│      Flutter Client       │        │       Cloudflare Worker Backend      │
│                           │        │                                      │
│  ConversationCrypto (V2)  │◄──────►│  V2 Auth & Device Middleware         │
│  (X25519 + XChaCha20)     │  HTTPS │  (active V2 identity key required)   │
│                           │  & WS  │                                      │
│  ConversationProvider     │        │  Routes & ChatRoom Durable Object    │
│  (V2 envelopes only)      │        │  • Devices & QR Pairing (V2 only)    │
│                           │        │  • Keys / Epochs / Envelopes         │
│  Local SQLite Store (v10) │        │  • Messages, Read & Media (V2 only)  │
│  (V2 messages only;       │        │  • Single-query Inbox & Requests     │
│   Signal store removed)   │        └──────────────────┬───────────────────┘
└───────────────────────────┘                           │
                                                        ▼
                              ┌─────────────────────────────────────────────┐
                              │            Cloudflare D1 (SQLite)           │
                              │                                             │
                              │  conversations                              │
                              │  • last_message_at, last_message_sender_id  │
                              │                                             │
                              │  conversation_user_state (PK: conv, user)   │
                              │  • unread_count, last_read_at, peer_seen_at │
                              │                                             │
                              │  messages (V2 ciphertext, nonce, auth_tag,  │
                              │            key_epoch, delivered_at, read_at)│
                              │                                             │
                              │  conversation_key_epochs &                  │
                              │  device_key_envelopes                       │
                              │                                             │
                              │  [Dropped: message_deliveries, pre_keys]    │
                              └─────────────────────────────────────────────┘
```

### Data Model & Forward-Only Schema Strategy

1. **V1 Purge & Legacy Drops**:
   - Delete `messages` where `encryption_version != 2` and `devices` where `encryption_version != 2`.
   - Drop `message_deliveries` and `pre_keys` tables.
   - Drop legacy message indexes tied to `encryption_version`, V1 reads, or global unsent counts before altering columns.
   - Drop Signal and version columns from `devices` (`legacy_device_id`, `registration_id`, `identity_key`, `signed_pre_key_id`, `signed_pre_key_public`, `signed_pre_key_signature`, `encryption_version`) and `encryption_version` from `messages`.
2. **New Incremental Conversation State**:
   - Add `last_message_sender_id` to `conversations`.
   - Create `conversation_user_state` with `(conversation_id, user_id)` composite primary key, `unread_count` (`DEFAULT 0`), `last_read_at`, and `peer_seen_at`, plus a covering user lookup index `idx_conversation_user_state_user(user_id, conversation_id)`.
   - Add `idx_messages_conv_sender_read` on `(conversation_id, sender_id, read_at) WHERE is_unsent = 0` strictly for bounded delete/read updates rather than inbox queries.
3. **Deterministic Backfill**:
   - Recompute `conversations.last_message_at` and `conversations.last_message_sender_id` from remaining active V2 messages (`is_unsent = 0`).
   - Seed two rows per conversation in `conversation_user_state` with exact unread counts, `last_read_at`, and `peer_seen_at` computed once during migration.

### Incremental State Mutation & Query Flows

| Operation | State Mutation / Query Strategy | Read Complexity Guarantee |
| :--- | :--- | :--- |
| **Create Conversation** | Batch-insert conversation row and both `(convId, userA)` / `(convId, userB)` rows into `conversation_user_state`. | Constant 3-row write |
| **Send Message (HTTP & WS)** | Require active V2 device + valid `ciphertext`, `nonce`, `auth_tag`, `key_epoch`; check duplicate `id` before mutating. Batch-insert message, set `conversations.last_message_at` & `last_message_sender_id`, increment recipient `unread_count` (`+1`), and `INSERT OR IGNORE` sender state row. | Zero delivery fan-out |
| **Delivery Ack (WS)** | Update `messages.delivered_at = COALESCE(delivered_at, ?)` guarded by `sender_id <> ? AND delivered_at IS NULL` and `meta.changes > 0` before broadcasting. | Single message update |
| **Mark Read** | Select unread peer message IDs and stamp `read_at` & `delivered_at`; reset reader `unread_count = 0` & `last_read_at = max`; update sender `peer_seen_at` if messages transitioned to read. Honor `disappearing_timer = -1` (delete) or `> 0` (`expires_at`). | Scoped to unread rows |
| **Unsend / Delete / Expiry** | Pre-aggregate deleted unread counts & read timestamps by `sender_id`, delete target messages/media, decrement recipient `unread_count` (`MAX(0, ...)`), and recompute `last_message_*` / `peer_seen_at` using partial indexes only as affected. | Single-conversation bounded |
| **Inbox & Single Conversation** | Drive queries from `conversation_user_state` joined to `conversations`, peer `users`, and `user_blocks`. Filter non-empty chats via `last_message_at IS NOT NULL` (zero `messages` joins or subqueries). Execute `scope=all` in one query. | O(user's conversations) |

### Verification Plan

- **Static & Unit Checks**: Run Worker TypeScript type-checking and Vitest suites after updating existing V1-referencing tests and adding tests covering V1 rejection (`400`/`403`/`404`/`410`), incremental state accuracy (send, duplicate send idempotency, multi-send, read, unsend, expiry, burn-after-read `-1`), and single-query `scope=all`.
- **Database Migration & Query Plan Verification**: Apply all migrations (`0001` through `0014`) against both a fresh SQLite/D1 database and a seeded pre-0014 database containing mixed V1/V2 messages and devices, verify V1 purge + V2 backfill accuracy, and run `EXPLAIN QUERY PLAN` on inbox and single-conversation queries to confirm zero table or index scans on `messages` or dropped tables.
