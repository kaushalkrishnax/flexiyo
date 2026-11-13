# Flexiyo — D1 SQL Efficiency Audit

Date: Fri Nov 13 2026
Scope: `worker/src` (API routes, Durable Objects, WebSocket handlers, services, cron/cleanup),
`worker/migrations` (schema + indexes), `scripts/loadtest` (V2 cost model).

## Executive summary

This audit reviews every D1 SQL query in the V2-only Flexiyo Worker. The baseline
codebase was already substantially optimized (V2-only schema, `message_deliveries`
and `pre_keys` dropped, `conversation_user_state` counters, partial indexes on
`messages`). Three optimization gaps were fixed:

1. **Read endpoint** — filter rewritten from `sender_id != ?` to `sender_id = peerId`
   so the existing partial index `idx_messages_conv_sender_read` is fully
   constrained; `SELECT + UPDATE` replaced with one `UPDATE ... RETURNING id`.
2. **Deletion path** — `json_each` drive-table joins replaced `id IN (...)` scans
   so each id is a primary-key probe instead of a full-conversation scan.
3. **User prefix search** — new forward-only migration `0015` adds
   `idx_users_username_nocase`, turning `SCAN users` into an index range seek.

No new indexes were added blindly; each was verified with `EXPLAIN QUERY PLAN`
(and, where measurable, `rows_read`) before and after.

## Audit methodology

- Every `env.DB.prepare(...)` / `drizzle` call across routes, services, Durable
  Objects (ChatRoom), and scheduled handlers was catalogued.
- For each query the plan was captured with `EXPLAIN QUERY PLAN` against a
  representative SQLite build of migrations `0001..0015` seeded with realistic
  volumes (20k users, 5k conversations, 200k messages). Plans match D1
  behaviour (D1 runs SQLite; `rows_read` assertions in tests confirm miniflare
  behaves the same).
- Rows scanned / returned are **estimates**, not exact measurements: the actual
  scan depends on table size and data distribution. Estimates are labelled as
  such.
- Tests assert `rows_read` bounds on the hot paths (read endpoint, deletions,
  delete-for-me) so regressions are caught automatically.

## Repository-wide query catalogue

### 1. Auth (`src/routes/auth.ts`, `src/middleware/auth.ts`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| A1 | `authMiddleware`: token revocation | `SELECT jti FROM token_revocations WHERE jti = ?` | token_revocations | PK `jti`, `idx_token_revocations_expires` | 0–1 | 1 (PK seek) | No | none | Low |
| A2 | Login: user lookup | `SELECT ... FROM users WHERE username = ? LIMIT 1` | users | `idx_users_username` (UNIQUE) | 0–1 | 1 | No | none | Low |
| A3 | Register: username existence | `SELECT ... FROM users WHERE username = ?` (Drizzle unique check) | users | UNIQUE index on username | 0–1 | 1 | No | none | Low |
| A4 | Logout: insert revocation | `INSERT INTO token_revocations ... ON CONFLICT DO NOTHING` | token_revocations | PK `jti` | — | 1 write | No | none | Low |
| A5 | `/me`: own user row | `SELECT ... FROM users WHERE id = ?` | users | PK `id` | 1 | 1 | No | none | Low |

**Verdict:** efficient. Token revocation is a PK seek; username/email/google lookups use unique or indexed columns.

### 2. User search (`src/routes/users.ts`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| U1 | GET `/api/users/search` | `SELECT id, username FROM users WHERE username LIKE '<prefix>%' AND id != ? LIMIT 20` | users | `idx_users_username` (BINARY unique) | ≤20 | **all users** before fix | **Yes** — a non-matching prefix still scans the whole table | Implemented: `idx_users_username_nocase` (migration 0015) | High |

**Before (verified):** `SCAN users` — every prefix search, including one matching nothing, reads every user row.
**After (verified):** `SEARCH users USING INDEX idx_users_username_nocase (username>? AND username<?)` — range seek, reads only the matching prefix range; `rows_read < 50` for a no-match prefix against 30k users.

The LIKE prefix is case-insensitive (ASCII) by default, so the BINARY unique index cannot serve it. A NOCASE index preserves exact case-insensitive semantics (verified identical results for `LIKE 'USER0001%'` and a NOCASE range).

### 3. Conversations (`src/routes/conversations.ts`, `src/services/conversationList.ts`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| C1 | Create conversation: participant lookup | `SELECT id, username FROM users WHERE id = ?` | users | PK `id` | 1 | 1 | No | none | Low |
| C2 | Create: existing conversation | `SELECT c.* ... FROM conversations c WHERE c.user_a_id = ? AND c.user_b_id = ?` | conversations | `idx_conversations_user_a`, `idx_conversations_user_b` | 0–1 | ~1–2 (index seek) | No | none | Low |
| C3 | Create: state upserts (×2) | `INSERT OR IGNORE INTO conversation_user_state ...` | conversation_user_state | `idx_conversation_user_state_user` | — | 1–2 writes | No | none | Low |
| C4 | Request decision | `UPDATE conversations SET request_status = ? WHERE id = ? AND request_status = 'pending'` | conversations | PK `id` | — | 1 | No | none | Low |
| C5 | Request decision: names + state | `SELECT ... FROM users WHERE id IN (?, ?)` / `SELECT ... FROM conversation_user_state WHERE conversation_id = ? AND user_id IN (?, ?)` | users, conversation_user_state | PKs | 2 / ≤2 | ≤4 | No | none | Low |
| C6 | List inbox/requests/blocked/all | `SELECT ... FROM conversation_user_state cus JOIN conversations c ... JOIN users ... LEFT JOIN user_blocks ... ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC` | conversation_user_state, conversations, users, user_blocks | `idx_conversation_user_state_user`, PKs | ≤ page size | bounded by inbox size (~all of user's conversations) | No — bounded by inbox, not message history | Temp B-tree sort documented as limitation; keyset pagination not yet needed | Medium |
| C7 | Conversation detail | `SELECT * FROM conversations WHERE id = ? AND (user_a_id = ? OR user_b_id = ?)` | conversations | PK `id` | 1 | 1 | No | none | Low |

**Verdict:** efficient. `conversation_list_all` is unbounded (returns the user's entire inbox) but bounded by inbox size, not by message history; documented as a limitation (no keyset pagination yet).

### 4. Messages — read (`src/routes/messages.ts`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| M1 | GET messages page | keyset `SELECT m.* FROM messages m LEFT JOIN local_deletions ... WHERE conversation_id = ? ... ORDER BY created_at DESC, id DESC LIMIT ?` | messages, local_deletions | `idx_messages_conv_active_latest`, `idx_local_deletions_user` (autoindex) | ≤100 | ~limit + few deletion probes | No | none | Low |
| M2 | POST read (implemented) | `UPDATE messages SET delivered_at = ..., read_at = ? WHERE conversation_id = ? AND sender_id = ? AND is_unsent = 0 AND read_at IS NULL RETURNING id` | messages | `idx_messages_conv_sender_read (conv, sender, read_at WHERE is_unsent=0)` | = unread count | ≈ unread count (≤20 with 1200-history) | **No** — reads only the unread set | Implemented: equality predicate + RETURNING | High |
| M2-baseline | old form (regression-tested) | `... WHERE sender_id != ? ...` | messages | same index | = unread | whole conversation range (~200k at scale) | **Yes** | rejected — replaced | High (fixed) |

**Before:** `SEARCH ... idx_messages_conv_sender_read (conversation_id=?)` — full conversation range (~200k rows at scale), `rows_read > HISTORY`.
**After:** `SEARCH ... (conversation_id=? AND sender_id=? AND read_at=?)` — covering index seek, `rows_read ≤ 20`. `UPDATE ... RETURNING` halves the unread scan (no separate SELECT) and prevents duplicate broadcasts/deletes under concurrent reads.

### 5. Messages — send (`src/sockets/chatRoom.ts` `handleSendMessage`/`persistMessage`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| S1 | Conversation gate | `CONVERSATION_GATE_SQL` (conversations + 2 EXISTS subqueries on messages) | conversations, messages | PK conversations, messages PK rowid | 1 row | 1 + 2 PK probes | No | none | Low |
| S2 | Pending-request prior message | `SELECT id FROM messages WHERE conversation_id = ? AND sender_id = ? AND is_unsent = 0 LIMIT 1` | messages | `idx_messages_conv_active_latest` | 0–1 | 1–2 | No | none | Low |
| S3 | Device + media + coverage | 3× batch: devices seek, media seek, coverage counts over devices/key envelopes | devices, media, device_key_envelopes | `idx_devices_user_status`, `idx_key_envelopes_recipient` | few | bounded (device counts) | No | none | Low |
| S4 | Write message + state | INSERT messages; UPDATE conversations; `INSERT ... ON CONFLICT ... unread_count + 1` × conversation_user_state | messages, conversations, conversation_user_state | PKs | — | ~5 writes | No | none | Low |
| S5 | Broadcast + push | WS fan-out (no D1) + `SELECT username FROM users WHERE id = ?` | users | PK | 1 | 1 | No | none | Low |

**Verdict:** efficient. All message-send SQL is bounded by seeks/primary-key probes; no history scan. The `ON CONFLICT unread_count + 1` increment is atomic and index-backed.

### 6. Messages — read receipts / deletion / expiration

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| D1 | `deleteMessages`: media lookup | `FROM json_each(?) ids CROSS JOIN messages m JOIN media ... WHERE m.id = ids.value AND m.conversation_id = ?` | messages, media | messages PK rowid | ≤ len(ids) | ≈ len(ids) PK probes | **No** | Implemented: json_each drive table | High |
| D2 | `deleteMessages`: impact aggregate | `FROM json_each(?) ids CROSS JOIN messages m WHERE m.id = ids.value ... GROUP BY m.sender_id` | messages | PK rowid | ≤ #senders | ≈ len(ids) probes | **No** | Implemented | High |
| D3 | `deleteMessages`: DELETE | `DELETE FROM messages WHERE rowid IN (SELECT m.rowid FROM json_each(?) ids CROSS JOIN messages m WHERE m.id = ids.value ...)` | messages | PK rowid | — | ≈ len(ids) probes | **No** | Implemented | High |
| D4 | `deleteMessages`: last-message re-derive | `SELECT created_at, sender_id FROM messages WHERE conversation_id = ? AND is_unsent = 0 ORDER BY created_at DESC, id DESC LIMIT 1` | messages | `idx_messages_conv_active_latest` | 1 | 1 | No | none | Low |
| D5 | `deleteMessages`: peer_seen_at | `SELECT MAX(read_at) FROM messages WHERE conversation_id = ? AND sender_id = ? ... AND read_at IS NOT NULL` | messages | `idx_messages_conv_sender_read` | 1 | few (sender slice) | No | none | Low |
| D6 | Delete-for-me validation | `SELECT ... FROM json_each(?) ids CROSS JOIN messages m WHERE m.id = ids.value AND ...` (rows_read ≤ 10) | messages | PK rowid | ≤ len(ids) | ≈ len(ids) probes | **No** | Implemented | High |
| D7 | Expiry sweep (`cleanExpiredMessages`) | `SELECT id, conversation_id FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ? ORDER BY expires_at ASC LIMIT 500` | messages | `idx_messages_expires` | ≤500 per run | ≤500 | No — bounded batch | none | Low |
| D8 | Disappearing timer → 0 | `UPDATE messages SET expires_at = NULL WHERE conversation_id = ?` | messages | `idx_messages_conv_created` | = messages in conv | full conversation | **Yes** (rare op) | Rejected — operation rare; non-partial index would add write on every insert | Residual |

**Verdict:** D1–D6 fixed to avoid full-conversation scans; D7 bounded by `LIMIT 500` per run; D8 documented residual (rare, write-cost tradeoff rejected).

### 7. Delete-for-me (`src/routes/messages.ts` POST `/delete-for-me`)

Uses `deleteMessages` (D1–D5) plus a validation lookup that now drives from
`json_each` CROSS JOIN. Reads ≈ number of ids, not the conversation. `rows_read ≤ 10`
asserted in tests.

### 8. Key management (`src/routes/keys.ts`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| K1 | POST key-epochs | conversation seek + `UPDATE conversations SET key_epoch = ? WHERE id = ? AND key_epoch = ?` + epoch insert + device seeks | conversations, conversation_key_epochs, devices | PKs, `idx_key_epochs_conversation` | 1 epoch | bounded (few devices) | No | none | Low |
| K2 | POST key-envelopes | conversation + device seeks + per-recipient upserts | conversations, devices, device_key_envelopes | PKs, `idx_key_envelopes_recipient` | — | ~4 reads + N writes | No | none | Low |
| K3 | GET key-envelopes | `SELECT ... FROM device_key_envelopes WHERE conversation_id = ? AND recipient_device_id = ? [AND epoch = ?]` | device_key_envelopes | `idx_key_envelopes_recipient` | N envelopes | N index seeks | No | none | Low |

**Verdict:** efficient. Bounded by devices/envelopes per conversation, not message history.

### 9. Devices (`src/routes/devices.ts`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| V1 | List devices | `SELECT * FROM devices WHERE user_id = ? ORDER BY created_at ASC` | devices | `idx_devices_user_created` | ≤5 active | index range | No | none | Low |
| V2 | Register v2 | installation seek + active count + insert | devices | `idx_devices_user_status`, PK | 1 | few | No | none | Low |
| V3 | Identity keys | `SELECT ... FROM devices WHERE user_id = ? AND status = 'active' ...` | devices | `idx_devices_user_status` | ≤5 | index range | No | none | Low |
| V4 | Disable/enable/delete | `closeRevokedDeviceSockets`: `SELECT id FROM conversations WHERE user_a_id = ? OR user_b_id = ?` + envelope delete + per-room DO broadcast | conversations, device_key_envelopes | `idx_conversations_user_a/b`, PK | user's convs | user's conversation count | No — bounded by user's conversations | none | Low |
| V5 | enable slot check | correlated `SELECT COUNT(*) FROM devices WHERE user_id = ? AND status IN (...)` | devices | `idx_devices_user_status` | 1 count | ≤ active devices | No | none | Low |

**Verdict:** efficient. `closeRevokedDeviceSockets` loops over the user's conversations (bounded, not global) and calls the Durable Object per room (not D1).

### 10. WebSocket / ChatRoom (`src/sockets/chatRoom.ts`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| W1 | WS connect: token revocation | `SELECT jti FROM token_revocations WHERE jti = ?` | token_revocations | PK | 0–1 | 1 | No | none | Low |
| W2 | WS connect: device active | `SELECT id FROM devices WHERE id = ? AND user_id = ? AND status = 'active' AND identity_public_key IS NOT NULL` | devices | PK + `idx_devices_user_status` | 0–1 | 1 | No | none | Low |
| W3 | delivery_ack | `UPDATE messages SET delivered_at = COALESCE(...) WHERE id = ? AND sender_id <> ? AND delivered_at IS NULL RETURNING sender_id` | messages | PK rowid | 0–1 | 1 | No | none | Low |
| W4 | broadcast / send_message fan-out | in-memory WS iteration; `notifyInboxes` → DO `/broadcast` (no D1) | — | — | — | — | No | none | Low |
| W5 | disconnect-device | in-memory socket iteration (no D1) | — | — | — | — | No | none | Low |

**Verdict:** efficient. All WS D1 access is PK-seek bounded.

### 11. Push (`src/services/push.ts`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| P1 | sendPushToUser | `SELECT token FROM push_tokens WHERE user_id = ? ORDER BY updated_at DESC LIMIT 10` | push_tokens | `idx_push_tokens_user` | ≤10 | ≤10 | No | none | Low |
| P2 | sendToToken prune | `DELETE FROM push_tokens WHERE token = ?` | push_tokens | UNIQUE token | — | 1 write | No | none | Low |

**Verdict:** efficient. Bounded by `MAX_PUSH_TOKENS_PER_USER = 10`.

### 12. Media (`src/routes/media.ts`, `src/services/mediaViews.ts`, `src/services/media_purge.ts`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| ME1 | Media upload/claim view | `INSERT INTO media_views ... ON CONFLICT ... WHERE count < ? RETURNING count` | media_views | `idx_media_views_media` | 1 | 1 | No | none | Low |
| ME2 | Media fetch | `SELECT * FROM media WHERE id = ?` | media | PK | 1 | 1 | No | none | Low |
| ME3 | Daily usage upsert | `INSERT INTO daily_usage ... ON CONFLICT ...` | daily_usage | PK (day,user_id,column) | 1 | 1 | No | none | Low |
| ME4 | Media purge (cron) | `SELECT id, r2_key FROM media WHERE expires_at < ? ORDER BY expires_at ASC LIMIT 200` | media | `idx_media_expires` | ≤200/run | ≤200 | No — bounded | none | Low |
| ME5 | Daily usage prune | `DELETE FROM daily_usage WHERE rowid IN (SELECT rowid FROM daily_usage WHERE day < date('now','-30 days') ORDER BY day ASC LIMIT 1000)` | daily_usage | `idx_daily_usage_day` | ≤1000/run | ≤1000 | No — bounded | none | Low |

**Verdict:** efficient. All cleanup is bounded by `LIMIT` per run.

### 13. Scheduled / maintenance (`src/services/expiry.ts`, `src/services/maintenance.ts`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| X1 | Expiry sweep | `SELECT id, conversation_id FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ? ORDER BY expires_at ASC LIMIT 500` | messages | `idx_messages_expires` | ≤500/run | ≤500 | No — bounded | none | Low |
| X2 | token_revocations prune | `DELETE ... WHERE jti IN (SELECT jti FROM token_revocations WHERE expires_at <= ? LIMIT 1000)` | token_revocations | `idx_token_revocations_expires` | ≤1000 | ≤1000 | No — bounded | none | Low |
| X3 | rate_limit_buckets prune | `DELETE ... WHERE key IN (SELECT key FROM rate_limit_buckets WHERE window_start < ? LIMIT 1000)` | rate_limit_buckets | `idx_rate_limit_buckets_window` | ≤1000 | ≤1000 | No — bounded | none | Low |
| X4 | email codes prune | `DELETE ... WHERE id IN (SELECT id FROM email_verification_codes WHERE expires_at <= ? LIMIT 1000)` | email_verification_codes | `idx_email_codes_expiry` | ≤1000 | ≤1000 | No — bounded | none | Low |
| X5 | pairing sessions prune | `DELETE ... WHERE id IN (SELECT id FROM pairing_sessions WHERE expires_at <= ? LIMIT 1000)` | pairing_sessions | `idx_pairing_expires` | ≤1000 | ≤1000 | No — bounded | none | Low |

**Verdict:** efficient. Every maintenance query uses `LIMIT` on an indexed expiry column; bounded batches.

### 14. Pairing (`src/routes/pairing.ts`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| Pair1 | create/join/accept | device + pairing session seeks by user_id/status | pairing_sessions, devices | `idx_pairing_user_status`, `idx_pairing_expires` | few | few | No | none | Low |

**Verdict:** efficient.

### 15. Brevo / email codes (`src/services/brevo.ts`)

| # | Source/function | SQL pattern | Tables | Indexes | Rows returned | Rows scanned | Historical scan? | Fix? | Priority |
|---|-----------------|-------------|--------|---------|---------------|--------------|------------------|------|----------|
| B1 | code lookup / prune | `SELECT ... FROM email_verification_codes WHERE user_id = ? LIMIT 1` / `SELECT id FROM email_verification_codes WHERE expires_at <= ? LIMIT 1000` | email_verification_codes | `idx_email_codes_expiry` | ≤1 / ≤1000 | bounded | No | none | Low |

**Verdict:** efficient.

## High-risk queries ranked by potential D1 read cost

| Rank | Query | Why risky | Status |
|------|-------|-----------|--------|
| 1 | U1 `users.search` prefix LIKE | Full `SCAN users` on every search, including no-match prefixes | **Fixed** (migration 0015 NOCASE index) |
| 2 | M2 old read form `sender_id != ?` | Scanned entire conversation per read (~200k rows at scale) | **Fixed** (equality + RETURNING) |
| 3 | D1–D3 deletion `id IN (...)` | Scanned full conversation per deleted message | **Fixed** (json_each CROSS JOIN) |
| 4 | C6 `conversation_list_all` | Unbounded result + temp B-tree sort; scales with inbox size | Documented limitation |
| 5 | D8 disappearing timer → 0 | Full conversation scan; rare operation | Documented residual |

## Already efficient queries

Auth revocation/lookup, login/register, conversation create/detail/list, message page (keyset), message send gate/write, delivery_ack, WS connect, key epochs/envelopes, device list/register/identity-keys, push token lookup, media fetch/view/daily-usage, all bounded cron/expiry/maintenance prunes, pairing, email codes.

## Queries needing optimization

Only U1, M2, D1–D3 needed changes; all are implemented. No further changes recommended — remaining items are documented limitations/residual risks, not defects.

## Proposed and implemented index changes

| Migration | Index | Reason | Verified |
|-----------|-------|--------|----------|
| `0015_users_username_nocase.sql` | `idx_users_username_nocase ON users(username COLLATE NOCASE)` | Turns `LIKE '<prefix>%'` user search from `SCAN users` into an index range seek; preserves case-insensitive semantics | `EXPLAIN QUERY PLAN` shows `SEARCH users USING INDEX ...`; `rows_read < 50` for no-match against 30k users |
| (none) | `idx_messages_conv_sender_read` already exists | Read endpoint now fully constrains it via `sender_id = ?` equality | `rows_read ≤ 20` with 1200-message history |
| (none) | `idx_messages_conv_active_latest` already exists | Keyset message pagination and last-message re-derive | plan uses index seek |

**Rejected indexes** (documented, not added):
- Partial `idx_messages_conv_unread_only ON messages(conversation_id, sender_id) WHERE is_unsent=0 AND read_at IS NULL`: SQLite refuses partial indexes whose predicate columns are updated; the UPDATE still scanned the conversation; adds write amplification.
- `(conversation_id, read_at[, sender_id])`: no benefit over the equality-prefix rewrite; extra write cost.
- Non-partial index for `UPDATE messages SET expires_at = NULL WHERE conversation_id = ?`: rare op; would add a write on every message insert.

## Before/after query-plan comparisons

Read endpoint (1200-message history):
- Before: `SEARCH m USING INDEX idx_messages_conv_sender_read (conversation_id=?)` → `rows_read > HISTORY` (~200k at scale).
- After: `SEARCH m USING COVERING INDEX idx_messages_conv_sender_read (conversation_id=? AND sender_id=? AND read_at=?)` → `rows_read ≤ 20`.

Deletion (`json_each` drive table):
- Before: `id IN (SELECT value FROM json_each(?))` scanned the conversation (~48–94 ms, tens of thousands of rows at scale).
- After: `json_each(?) CROSS JOIN messages m WHERE m.id = ids.value` → ≈1–3 rows per id (PK probes).

User search:
- Before: `SCAN users` (30k rows for a no-match prefix).
- After: `SEARCH users USING INDEX idx_users_username_nocase (username>? AND username<?)` (< 50 rows).

## Remaining limitations and unverified assumptions

1. `conversation_list_all` (scope=all) returns the user's entire inbox with a temp B-tree sort; bounded by inbox size, not message history. Keyset pagination not implemented; acceptable for inbox-scale data.
2. `disappearing_clear` (`UPDATE messages SET expires_at = NULL WHERE conversation_id = ?`) scans the full conversation; operation is rare (timer→0), and an index would add write cost on every insert — documented residual.
3. `rows_read` / scan estimates are from local SQLite probes; D1's actual rows_read may differ slightly without ANALYZE statistics. Tests assert `rows_read` bounds to guard regressions.
4. D1 `EXPLAIN QUERY PLAN` against the deployed D1 database (with real data distribution and ANALYZE state) has not been run; local plans are representative but not production measurements.
5. No PostgreSQL, no Drizzle migration, no blanket conversion; raw SQL retained on hot paths per project rules.

## Tests added / updated

- `worker/tests/messageReadPlan.test.ts` — 12 tests: unread read on large history, multi-device read state, idempotency, no-unread counter repair, rows_read bounds, deletion impact/DELETE via json_each, delete-for-me validation, `UPDATE ... RETURNING` behavior. All pass.
- `worker/tests/userSearchPlan.test.ts` — 5 tests: index seek (no `SCAN users`), bounded rows_read for no-match prefix, page-limit stopping, case-insensitive match, empty unknown prefix. All pass.
- Full suite: 25 files / 209 tests passing; `tsc --noEmit` clean.
