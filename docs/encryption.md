# Encryption Design and Implementation

## Selected Protocol

**Signal Protocol** — specifically the combination of:

- **X3DH** (Extended Triple Diffie–Hellman) for initial key agreement
- **Double Ratchet Algorithm** for ongoing message encryption

This is the same protocol used by Signal, WhatsApp, and other major secure messaging applications.

---

## Implementation

**Library**: [`libsignal_protocol_dart`](https://pub.dev/packages/libsignal_protocol_dart)  
**Version**: 0.8.2  
**Publisher**: mixin.dev (verified publisher)  
**Repository**: [MixinNetwork/libsignal_protocol_dart](https://github.com/MixinNetwork/libsignal_protocol_dart)  
**Language**: Pure Dart (no native C/C++ or Rust bindings required)  
**Platform support**: Android, iOS, Linux, macOS, Windows, Web

This library is a port of the Signal Protocol Java implementation to Dart. It is used in production by the Mixin Messenger ecosystem.

---

## Licence

**`libsignal_protocol_dart` is licensed under GPL-3.0.**

### Obligations

Under GPL-3.0, if you distribute an application that links or incorporates this library, you must:

1. Make the corresponding complete source code of the application available to recipients under the GPL-3.0 or a compatible licence.
2. Include the GPL-3.0 licence text with the distribution.
3. Preserve all copyright and licence notices.

Flexiyo is distributed under the GNU Affero General Public License v3.0 (AGPL-3.0). Under Section 13 of GPLv3, linking with AGPL-3.0 code into a single combined work is explicitly permitted, satisfying the source-disclosure and copyleft requirements of `libsignal_protocol_dart`.

The `libsignal_protocol_dart` copyright notice must be preserved and included in distributions. See the [LICENSE file](https://github.com/MixinNetwork/libsignal_protocol_dart/blob/main/LICENSE) in the upstream repository.

---

## Key Types

| Key | Description | Where stored |
|---|---|---|
| Identity key pair | Long-term device identity (Curve25519) | Private: flutter_secure_storage / Public: D1 |
| Signed pre-key pair | Medium-term ephemeral key, signed by identity key | Private: flutter_secure_storage / Public: D1 |
| One-time pre-keys | Single-use keys for X3DH (batch of 100) | Private: flutter_secure_storage / Public: D1 (consumed on use) |
| Session state | Double Ratchet state per conversation | Encrypted in sqflite local DB |
| Message keys | Derived per-message during ratchet | Never stored; derived and discarded |

---

## Key Generation

At registration time, the Flutter client generates:

```dart
final identityKeyPair = generateIdentityKeyPair();        // Curve25519 keypair
final registrationId = generateRegistrationId(false);     // Random 14-bit integer
final preKeys = generatePreKeys(0, 100);                  // 100 one-time pre-keys
final signedPreKey = generateSignedPreKey(identityKeyPair, 0); // Signed with identity key
```

The private parts of all keys are stored exclusively in flutter_secure_storage. The public parts are uploaded to the server as a key bundle.

---

## Key Storage

### Private keys

Stored in **flutter_secure_storage**:

- iOS: Keychain Services (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
- Android: Android Keystore + EncryptedSharedPreferences

Private keys are never written to disk in plaintext, never logged, and never transmitted to the server.

### Session state

The Signal Protocol Double Ratchet maintains a session state that evolves with each message. This state is serialized and stored in a local sqflite table (`signal_sessions`). It is not end-to-end encrypted at rest beyond device encryption, but it cannot decrypt messages without the private identity key.

### Server storage

The server stores in D1:
- Public identity key (base64)
- Signed pre-key ID, public key, and identity-key signature
- One-time pre-keys (public only; consumed on use)

The server does **not** store:
- Any private key material
- Session state
- Derived message keys

---

## Session Establishment (X3DH)

When Alice wants to send the first message to Bob:

1. Alice fetches Bob's public key bundle from the server (`GET /api/devices/:userId/key-bundle`).
2. The server provides Bob's identity key, signed pre-key, and one one-time pre-key (removing it from the store).
3. Alice's client calls `sessionBuilder.processPreKeyBundle(bundle)` from libsignal_protocol_dart.
4. This executes the X3DH handshake locally, producing a shared secret.
5. Alice can now encrypt a message using `sessionCipher.encrypt()`.
6. The resulting ciphertext is a `PreKeySignalMessage` (type 3) — it contains enough information for Bob to complete the handshake.
7. Bob, on receiving this message, calls `sessionCipher.decryptPreKeyWhisperMessage()`, which completes the X3DH from his side and establishes the session.

No plaintext is transmitted at any point. The server delivers the encrypted `PreKeySignalMessage` ciphertext without being able to read it.

---

## Message Encryption (Double Ratchet)

After session establishment, every message uses the Double Ratchet:

1. The sender calls `sessionCipher.encrypt(utf8.encode(plaintext))`.
2. This returns a `CiphertextMessage` (a `SignalMessage`, type 1 after the initial handshake).
3. The ciphertext bytes are base64-encoded and sent to the server as `encryptedPayload`.
4. The recipient fetches the message and calls `sessionCipher.decrypt(message)`.
5. The Double Ratchet advances: forward secrecy is provided because past session states are deleted.

### Authenticated encryption

The Signal Protocol uses AES-256-CBC with HMAC-SHA256 (via the Double Ratchet's symmetric ratchet). Messages are authenticated; tampering causes decryption to fail.

---

## Message Editing (E2EE)

Edits are also encrypted:

1. The sender re-encrypts the new plaintext with the current session cipher.
2. The server replaces the `encrypted_payload` in D1.
3. The recipient decrypts the new payload.

Note: The session state advances with each encrypt/decrypt call. A replay of an old encrypted edit is rejected by the ratchet's message counter.

---

## Key Rotation

### One-time pre-keys

The server maintains a pool of one-time pre-keys. When a session is established, one is consumed. The Flutter client monitors the remaining count (`GET /api/devices/prekeys/count`) and replenishes when low (`POST /api/devices/prekeys/replenish`).

If no one-time pre-keys are available, the server returns a bundle without one (using only the signed pre-key). This is less ideal (reduces forward secrecy of the initial handshake) but is a supported fallback in the X3DH specification.

### Signed pre-key rotation

Signed pre-keys should be rotated periodically (e.g., weekly). The initial implementation does not automate this rotation. Future work should implement periodic signed pre-key rotation with server-side replacement.

### Identity key

Identity keys are long-term. Changing the identity key on a device resets all sessions. Recipients are not automatically notified of identity key changes in the initial implementation (a TOFU-trust model). Future work should implement safety number verification.

---

## Device Management

The initial release supports one device per user. The `devices` table in D1 enforces `UNIQUE(user_id, device_id)`.

Multi-device sync (e.g., sending to multiple devices, sealed sender) is not implemented in the initial release and would require significant additional protocol work.

---

## Session Recovery

If session state is lost (e.g., app reinstall, local DB deletion), the client must:

1. Re-register device with fresh keys (`POST /api/devices/register`).
2. Old sessions with other users are broken — they will need to establish a new session.
3. Messages encrypted under old sessions cannot be decrypted.

This is a fundamental property of the Signal Protocol's forward secrecy: no recovery of past messages is possible after key loss.

---

## Message Deletion and Expiration Guarantees

### What is guaranteed

- The server will not return expired or unsent messages through normal API calls.
- The server will delete `encrypted_payload` from D1 for expired messages via the scheduled cleanup.
- Connected recipients receive real-time deletion/expiry events via Durable Objects.
- Offline recipients receive deletion/expiry state on reconnection via normal message history queries.
- Local tombstones prevent deleted messages from reappearing after sync.

### What is NOT guaranteed

- **Recipient already read it**: Once a recipient has decrypted and displayed a message, the plaintext exists on their device. Unsending or expiring cannot erase it from their screen, memory, or notes.
- **Screenshots**: Cannot be prevented or detected.
- **Backups**: Device backups may contain the local sqflite database including decrypted message cache.
- **Flash storage forensics**: Deleted rows in sqflite may persist in unallocated flash pages.
- **External copies**: If the recipient copied, exported, or screen-recorded the message, those copies are outside the application's control.
- **Offline devices**: A device that receives a message while online and then goes offline before the expiry cleanup cannot have its local copy remotely deleted. The application enforces expiry locally using the `expires_at` timestamp that was included in the message metadata.

Do not rely on disappearing messages or unsend as a guarantee of permanent deletion. They are best-effort mechanisms for removing application-managed copies.
