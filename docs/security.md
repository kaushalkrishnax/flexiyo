# Security Model and Threat Boundaries

## Overview

This document describes what Flexiyo protects against, what the server can and cannot see, and where trust boundaries lie.

---

## End-to-End Encryption vs. Other Security Layers

These are distinct, complementary protections:

| Layer | What it protects |
|---|---|
| **E2EE (conversation keys + legacy Signal)** | Message plaintext from the server and network attackers |
| **HTTPS / TLS** | Message payloads in transit from passive eavesdroppers |
| **Password hashing (PBKDF2)** | Passwords from database-level attackers |
| **JWT authentication** | API endpoints from unauthorized access |
| **flutter_secure_storage** | Private keys from other apps on the device |

HTTPS protects ciphertext in transit. E2EE protects the plaintext from the server itself. These layers are not redundant.

---

## What the Server Can See (Metadata)

Even with E2EE, the Cloudflare Worker has visibility into:

- Account identifiers and usernames
- Which users have conversations with each other
- When messages were sent (timestamps)
- Message sizes (approximate)
- Whether a message was edited or unsent
- Expiry timestamps
- Public cryptographic key material (identity public keys, conversation-key envelope metadata)
- Delivery state (whether a message was delivered or read)
- Device registration times, device status, and key-epoch numbers

The Worker cannot see:
- Message plaintext
- User passwords (PBKDF2-hashed before transmission)
- Private identity keys
- Session state
- Conversation keys derived per epoch

---

## What the Server Cannot Do

- Decrypt any message — it only stores ciphertext
- Read message content in transit (HTTPS + E2EE)
- Impersonate a user's private key
- Inject messages that pass decryption verification (authenticated encryption)
- Substitute pairing keys without failing the client-side AEAD proof check
- Deliver conversation keys to revoked devices (revocation forces a new epoch)

---

## Threat Model

### Threats Mitigated

| Threat | Mitigation |
|---|---|
| Passive network eavesdropping | TLS + E2EE |
| Server-side data breach | E2EE: only ciphertext in D1 |
| Password database leak | PBKDF2 with per-user salt |
| Unauthorized API access | JWT + conversation membership validation |
| Token theft | Short-lived JWTs, revocation on logout |
| SQL injection | Prepared statements only |
| Replay attacks | JWT expiry; message version concurrency checks |
| Unauthorized edits | Server validates sender_id from JWT |
| Unauthorized unsend | Server validates sender_id from JWT |
| Message resurrection after deletion | Server rows are hard-deleted; local tombstones cover delete-for-me |
| Expired message exposure | Server filters at query time; client enforces locally |

### Threats NOT Mitigated (Documented Limitations)

| Threat | Reason |
|---|---|
| Compromised endpoint device | If the device is compromised, all local decrypted messages are accessible |
| Recipient screenshots / copies | Cannot be prevented; unsend is best-effort |
| Metadata analysis | Conversation graph and timing are visible to the server |
| Key-substitution attacks (TOFU) | Trust-on-first-use; no out-of-band safety-number UI. Pairing verifies the joining device with an AEAD proof, but the user must scan a QR code generated on their own device. |
| Compromised authorized installation | A device holding a conversation key can read every message in that epoch |
| Replay of a pending QR code | QR payloads are single-use and expire after 180 seconds; proof verification still gates approval |
| Denial of service during pairing | The Worker can refuse to relay pairing messages; it cannot approve a device on its own |
| Forward secrecy after local key theft | Conversation keys are static per epoch (v2); a stolen epoch key exposes every message in it. |
| Flash storage forensics | Deleted data on SSD/eMMC may persist in wear-leveling blocks |
| OS-level memory inspection | Decrypted plaintext exists in process memory during display |
| Cloudflare as infrastructure provider | Cloudflare can observe metadata and timing; they cannot decrypt payloads |

---

## Authentication and Session Security

- Passwords are never logged or stored in plaintext.
- PBKDF2-SHA256 with 100,000 iterations, 16-byte random salt, 32-byte output.
- JWTs are HS256, signed with a secret stored as a Wrangler secret (not in source control).
- JWT expiry: 7 days. Longer sessions require re-authentication.
- Logout revokes the token by storing the `jti` in D1 (token_revocations table).
- Revoked tokens are rejected on all subsequent requests.

---

## Key Management

See [`encryption.md`](encryption.md) for the full key lifecycle.

Private keys never leave the client device. They are stored in flutter_secure_storage:
- iOS: Keychain Services
- Android: Android Keystore-backed EncryptedSharedPreferences

The server stores only public key material required for conversation-key envelope distribution.

---

## Input Validation and Injection Prevention

- All API request bodies are validated with Zod schemas.
- All D1 queries use prepared statements with bound parameters.
- Untrusted input is never interpolated into SQL strings.
- Username allowed characters: `[a-zA-Z0-9_]`, 3–30 characters.
- Password length: 8–128 characters.
- Message payload size: validated at API layer.
- Integer overflow: D1 integer columns bounded by SQLite limits.

---

## Transport Security

- Production Worker URL: `https://flexiyo.kaushalkrishnax.workers.dev` (TLS provided by Cloudflare).
- TLS certificate verification is not disabled anywhere in the Flutter client.
- Local development uses HTTP only on loopback addresses.

---

## Rate Limiting

Simple in-memory rate limiting is applied to:
- `POST /api/auth/register` — max 5 requests per IP per minute
- `POST /api/auth/login` — max 10 requests per IP per minute
- `GET /api/users/search` — max 30 requests per IP per minute

Note: Cloudflare Workers are stateless; rate limit state resets across Worker restarts. For production hardening, use Cloudflare Rate Limiting rules or Durable Objects for distributed rate limiting.

---

## Local Deletion and Secure Deletion Limitations

Local deletion marks messages with an `is_locally_deleted` tombstone in sqflite. This prevents the message from appearing in the UI or being restored during sync.

However:
- The sqflite database is not encrypted at rest by default (file-level encryption depends on device encryption being enabled).
- Flash storage does not guarantee immediate overwrite of deleted data.
- The operating system may retain file-system metadata.
- Backups (iCloud, Google Drive) may contain copies of the local database before deletion.

For security-sensitive deployments, full-disk encryption on the device is the primary protection against local data recovery.

---

## Disappearing Messages — Guarantees and Limitations

Disappearing timers start when the recipient reads a message, not when it is sent. With "disappear immediately", the read route deletes the message rows outright; with a longer timer, the read route stamps `expires_at` and the cleanup job removes the rows once it passes. The server filters expired messages from all API responses immediately, regardless of cleanup job status, and connected devices purge them locally on the deletion events.

Limitations:
- A recipient who was online when the message was delivered received the plaintext locally. The expiry system cannot erase it from their memory or notes.
- An offline recipient who reconnects after expiry will not receive the expired message.
- If a recipient's device cached the decrypted plaintext and backs up their phone, the content may survive in the backup.
- The expiry is enforced by trusted server time. Clients that manipulate their clock cannot extend server-side expiry but may see locally expired messages momentarily before sync.
