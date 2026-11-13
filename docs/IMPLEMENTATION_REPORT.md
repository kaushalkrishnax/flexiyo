# Flexiyo — D1 Performance Implementation Report

Date: Fri Nov 13 2026
Branch: created from `main` (see git section below)
Status: changes implemented locally; tests pass; type-check clean; not merged, not deployed.

## Objective

Implement narrowly scoped D1 SQL performance improvements in the V2-only Flexiyo repo and produce a repository-wide D1 SQL audit. All changes preserve API compatibility (read receipts, `conversation_user_state` counters, `peer_seen_at`, WebSocket broadcasts, disappearing-message expiry, multi-device, idempotency). No PostgreSQL, no project-wide Drizzle migration, no modifications to existing migrations (forward-only new migration allowed), no deploy, no push to `main`.

## Files changed

| File | Change |
|------|--------|
| `worker/migrations/0015_users_username_nocase.sql` (new) | Forward-only migration adding `idx_users_username_nocase ON users(username COLLATE NOCASE)` with comment explaining the LIKE prefix seek. |
| `worker/src/routes/messages.ts` | Read endpoint: filter rewritten from `sender_id != ?` to `sender_id = peerId`; `SELECT + UPDATE` replaced with a single `UPDATE ... RETURNING id`. Delete-for-me validation lookup rewritten to drive from `json_each` CROSS JOIN. |
| `worker/src/services/message_deletion.ts` | `deleteMessages`: media lookup, impact aggregate, and DELETE all rewritten to drive from `json_each(?) ids CROSS JOIN messages m WHERE m.id = ids.value` (primary-key probes) instead of `id IN (...)` conversation scans. |
| `worker/tests/messageReadPlan.test.ts` (new) | 12 regression tests: unread read on large history (1200 messages), multi-device read state (`X-Installation-Id` header), idempotency / no re-stamping, no-unread counter repair, `rows_read` bounds (≤20 read, >HISTORY old form), deletion impact + DELETE via json_each, delete-for-me validation, `UPDATE ... RETURNING` behavior. |
| `worker/tests/userSearchPlan.test.ts` (new) | 5 tests: `EXPLAIN QUERY PLAN` uses `idx_users_username_nocase` with no `SCAN users`; bounded `rows_read` for no-match prefix (<50 against 30k users); page-limit stopping; case-insensitive match excluding caller; empty unknown prefix. |
| `scripts/loadtest/costs.js` | Rewritten for V2 schema: removed `message_deliveries`/`pre_keys`/per-device acks; models actual V2 queries; distinguishes scanned vs returned rows; normal/high-volume/stress scenarios; plan-aware cost functions. |
| `scripts/loadtest/index.js` | V2 flow: `/api/devices/v2/register` with `identityPublicKey` (32B base64), `POST /api/conversations/:id/key-epochs` epoch 1 with envelopes for all active devices (`ephemeralPublicKey` 32B, `nonce` 24B, `mac` 16B, non-empty ciphertext), `send_message` with `encryptionVersion:2, ciphertext, nonce(24B), authTag(16B), keyEpoch`, plus `X-Installation-Id`. Removed pre_keys. `--scenario` flag added. |
| `scripts/loadtest/report.js` | `D1_TABLES` updated for V2 schema (removed `pre_keys`, `message_deliveries`; added V2 tables). |
| `scripts/loadtest/scenario.js` | Added `--scenario` option (normal/high-volume/stress). |
| `docs/SQL_AUDIT_REPORT.md` (new) | Repository-wide D1 SQL audit. |

Uncommitted pre-existing worktree changes (`ios/Runner.xcodeproj/project.pbxproj`, `lib/core/app_version.dart`, `package.json`, `pubspec.lock`, `pubspec.yaml`) were intentionally left untouched and uncommitted.

## Queries optimized

### 1. Read endpoint (`POST /api/conversations/:id/read`)

**Before:** `SELECT id FROM messages WHERE conversation_id = ? AND sender_id != ? AND is_unsent = 0 AND read_at IS NULL` followed by a separate `UPDATE ... SET read_at = ? WHERE id IN (...)`. Plan: `SEARCH ... idx_messages_conv_sender_read (conversation_id=?)` — full conversation range (~200k rows at scale); `rows_read > HISTORY`.

**After:** Single `UPDATE messages SET delivered_at = COALESCE(delivered_at, ?), read_at = ? WHERE conversation_id = ? AND sender_id = ? AND is_unsent = 0 AND read_at IS NULL RETURNING id`. Plan: `SEARCH ... (conversation_id=? AND sender_id=? AND read_at=?)` — covering index seek; `rows_read ≤ 20` with a 1200-message history. Halves the unread scan (no separate SELECT) and prevents duplicate broadcasts/deletes under concurrent reads.

### 2. Deletion path (`deleteMessages`, delete-for-me validation)

**Before:** `id IN (SELECT value FROM json_each(?))` scanned the conversation per deleted message (~48–94 ms scans).

**After:** `json_each(?) ids CROSS JOIN messages m WHERE m.id = ids.value AND m.conversation_id = ?` — each id is a primary-key probe; ≈1–3 rows read per id instead of a full-conversation scan. Applied to media lookup (with media join), impact aggregate, DELETE via rowid subquery, and delete-for-me validation.

### 3. User prefix search (`GET /api/users/search?q=<prefix>`)

**Before:** `SELECT id, username FROM users WHERE username LIKE '<prefix>%' AND id != ? LIMIT 20` → `SCAN users` (every user row, even for no-match prefixes).

**After:** Migration `0015` adds `idx_users_username_nocase ON users(username COLLATE NOCASE)`. Plan: `SEARCH users USING INDEX idx_users_username_nocase (username>? AND username<?)`; `rows_read < 50` for a no-match prefix against 30k users. Case-insensitive LIKE semantics preserved (verified identical results).

## Indexes added / rejected

| Index | Migration | Decision | Reason |
|-------|-----------|----------|--------|
| `idx_users_username_nocase ON users(username COLLATE NOCASE)` | `0015_users_username_nocase.sql` | **Added** | Turns `SCAN users` into index range seek; preserves LIKE prefix semantics; verified with/without ANALYZE. |
| `idx_messages_conv_unread_only (conv, sender) WHERE is_unsent=0 AND read_at IS NULL` | — | **Rejected** | SQLite refuses partial indexes whose predicate columns are updated; the UPDATE still scanned the conversation; adds write amplification. |
| `(conversation_id, read_at[, sender_id])` | — | **Rejected** | No benefit over equality-prefix rewrite; extra index write cost. |
| Non-partial index for `UPDATE messages SET expires_at = NULL WHERE conversation_id = ?` | — | **Rejected** | Rare op (timer→0); non-partial index would add a write on every message insert. Documented residual. |

## Before/after rows-scanned change

| Query | Before (estimate) | After (measured) |
|-------|-------------------|------------------|
| Read endpoint, 1200-history | >1200 (whole conversation range) | ≤20 (`rows_read` asserted) |
| Read endpoint, 200k-history | ~200k | ≤ unread count |
| Deletion per message | tens of thousands (conversation scan) | ≈1–3 (PK probe) |
| Delete-for-me validation | conversation scan | ≤10 (`rows_read` asserted) |
| User search, no-match prefix | all users (~30k) | <50 |

## Tests run

- `cd worker && bunx tsc --noEmit` — clean.
- `cd worker && bunx vitest run --max-workers=1` — **25 files / 209 tests passing**, 0 failures.
  - Includes new `messageReadPlan.test.ts` (12 tests) and `userSearchPlan.test.ts` (5 tests).
- Load-test cost model rewritten and syntax-checked (`node --check`/`bun` parse OK); not executed against a live Worker (requires `bun run dev`).

## Remaining concerns / limitations

1. `conversation_list_all` (scope=all) returns the user's entire inbox with a temp B-tree sort; bounded by inbox size, not message history. Keyset pagination not implemented; documented as acceptable for inbox-scale data.
2. `disappearing_clear` (`UPDATE messages SET expires_at = NULL WHERE conversation_id = ?`) scans the full conversation; operation is rare; index rejected due to write cost on every insert. Documented residual.
3. `rows_read` / scan estimates are from local SQLite probes; D1's actual `rows_read` may differ slightly without ANALYZE statistics. Tests assert bounds to guard regressions.
4. `EXPLAIN QUERY PLAN` was run against a local SQLite build of migrations `0001..0015`, not against the deployed D1 database with real data distribution. Local plans are representative but not production measurements.

## Git / branch / PR

- Work is on the current checkout of `main` (no feature branch created yet).
- Attempting to create a feature branch and PR requires GitHub authentication/permissions that have not been verified in this environment.
- If `git push` / `gh pr create` fails, the work is left ready locally: all changes are in the worktree, uncommitted, with the two new test files and migration present; the exact blocker will be recorded and no PR will be claimed.

Next steps: create a feature branch, commit the D1 changes (excluding the pre-existing uncommitted worktree changes), attempt the PR against `main`, and record the exact blocker if GitHub auth/permissions prevent it.
