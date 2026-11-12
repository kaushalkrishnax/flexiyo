# Flexiyo Progress Snapshot

## Project status

Flexiyo is a working end-to-end encrypted messenger. The Flutter client and the
Cloudflare Worker backend build, analyze, and test cleanly. New messages use
conversation-key encryption (XChaCha20-Poly1305) with per-device key envelopes;
legacy Signal messages remain decryptable.

## Verified project state

Last verified locally:

- `flutter analyze` — no issues.
- `flutter test` — 67 tests passed.
- `cd worker && bun run type-check` — clean.
- `cd worker && bun run test` — 21 files, 197 tests passed.
- `flutter build web` — builds successfully with `qr_flutter` and `mobile_scanner`.

Remote deployment is exercised through D1 migrations, `bun run
db:migrate:remote`, and `bun run deploy`.

## Implemented areas

- **Conversation-key encryption (v2):** one ciphertext per message;
  XChaCha20-Poly1305 with a 24-byte nonce; associated data binds conversation
  id, message id, and key epoch. Conversation keys are random 32-byte secrets
  wrapped per device with X25519 + HKDF-SHA256.
- **Key epochs and rotation:** compare-and-swap epoch publishing, stale-epoch
  rejection, rotation-required blocking after device revocation, and envelopes
  limited to authorized active devices.
- **QR device pairing:** QR generation, camera scanning with a paste fallback,
  expiring single-use sessions, client-side AEAD proof verification, approval
  restricted to the initiating device, and per-conversation key provisioning
  for the new device. See [pairing.md](pairing.md).
- **Legacy compatibility:** v1 Signal rows still decrypt and keep their edit,
  delete, and unsend behavior. New messages never use the v1 path.
- **Messaging:** edit, unsend for everyone, delete for me, copy, reactions,
  replies, and disappearing messages that start on read and purge on both sides.
- **Pagination and chat UX:** latest 10 messages on open, older messages in
  batches of 10 with cursor pagination and de-duplication, viewport preservation
  when older messages are inserted, composer/keyboard inset handling, a
  centered drop-shaped new-message indicator with the sender's avatar, and lazy
  media loading. When the cursor row has expired or been deleted, the client's
  copy of its timestamp keeps paging working.
- **Message requests:** first-contact messages land in a request inbox, with
  per-conversation permissions enforced in the Worker.
- **Encrypted media:** photos and voice notes encrypted on-device (AES-GCM);
  view-once / view-twice / unlimited policies enforced server-side; expired
  media purged by the Worker.
- **Accounts and devices:** username/password auth, email verification,
  Google Sign-In, device-isolated key storage, device listing and revocation.
- **Notifications:** Android push via Firebase Cloud Messaging; notifications
  never include message content.
- **Apps and updates:** Android APK distribution with an in-app updater; Flutter
  web build deployed to Cloudflare Pages.

## Partially implemented or missing

- Push notifications are Android-only. iOS needs APNs wiring and web push is not
  implemented.
- The approving device must be online while pairing wraps keys for existing
  conversations. Conversations created later need no manual step.
- Epoch keys are static for the life of the epoch: no per-message ratchet, so a
  compromised conversation key exposes every message in that epoch.
- Performance work is unfinished: no reproducible before/after load-test
  numbers have been recorded in this repository. See `docs/development.md` for
  the commands needed to measure them in a deployed environment.
- Test depth around conversation and media widget flows is still growing.
- Flexiyo has not undergone an independent security audit.

## Current blockers

None for the local build and test suites. Load-test measurements require a
deployed Worker and D1 database; they cannot be produced by the local Vitest
harness.

## Recommended next steps

1. Run the load-test harness against a staging deployment and record message
   latency, D1 rows read/written, and WebSocket fan-out.
2. Wire iOS push and follow with web push.
3. Add widget tests for the conversation viewport/composer and pairing screens.
4. Schedule an independent security review before a broad launch.

## Evidence

```
flutter analyze
flutter test
cd worker && bun run type-check
cd worker && bun run test
```
