# Encryption Design and Implementation

Flexiyo currently ships two message encryption versions side by side:

- **Version 2 (conversation keys)** is used for all new messages. It uses
  per-conversation keys, XChaCha20-Poly1305 authenticated encryption, and
  X25519-wrapped key distribution to each authorized device.
- **Version 1 (Signal Protocol)** remains available so messages written before
  the migration still decrypt. New messages never use this path.

`message.encryption_version` selects the path. The Worker never sees plaintext;
D1 stores one ciphertext per v2 message rather than one copy per device.

---

## Version 2: Conversation Keys

### Primitives

| Purpose | Primitive |
|---|---|
| Message encryption | XChaCha20-Poly1305 (24-byte nonce, 16-byte tag) |
| Key wrapping | X25519 + HKDF-SHA256 + XChaCha20-Poly1305 |
| Key derivation | HKDF-SHA256, 32-byte output |
| Randomness | `Random.secure()` for conversation keys, secrets and nonces |
| Implementation | [`cryptography`](https://pub.dev/packages/cryptography) 2.x on the client |

### Key hierarchy

| Key | Lifetime | Stored where |
|---|---|---|
| Conversation key (32 bytes) | One key epoch | Client secure storage, once per epoch |
| Identity private seed (32 bytes) | Installation lifetime | Client secure storage |
| Identity public key | Installation lifetime | D1 `devices.identity_public_key` |
| Wrapping key | One envelope | Derived on demand, never stored |
| Pairing secret (32 bytes) | One pairing session | Initiator secure storage only |
| Pairing ephemeral private key | One pairing session | Initiator secure storage only |

The Worker stores only public keys, opaque key envelopes, and epoch numbers.

### Message format

One v2 message row stores:

- `ciphertext` — XChaCha20-Poly1305 ciphertext (base64)
- `nonce` — 24-byte nonce (base64)
- `auth_tag` — 16-byte Poly1305 tag (base64)
- `key_epoch` — the conversation epoch used to encrypt it
- `encryption_version = 2`

Associated data is the JSON array:

```json
["flexiyo-message-v2", conversationId, messageId, keyEpoch]
```

Any change to the conversation id, message id, or epoch makes decryption fail
with an authentication error. A failed decryption never returns partial
plaintext; the client keeps the message in its encrypted state.

Each encryption call generates a fresh 24-byte nonce with the library's CSPRNG.
A nonce is never reused with the same conversation key.

### Key envelopes

A conversation key is wrapped once per authorized device:

1. Generate an ephemeral X25519 key pair.
2. Compute `shared = X25519(ephemeralPrivate, recipientIdentityPublic)`.
3. Derive `wrappingKey = HKDF-SHA256(shared, salt = nonce, info = aad)`.
4. Encrypt the 32-byte conversation key with XChaCha20-Poly1305.

Envelope associated data is the JSON array:

```json
["flexiyo-key-envelope-v2", conversationId, epoch, recipientDeviceId]
```

Binding the recipient device id prevents an envelope from being replayed to a
different device. Envelopes are stored in `device_key_envelopes` and are only
returned to the device they address.

### Epoch lifecycle

- `conversations.key_epoch` is the highest published epoch (0 = none).
- `conversation_key_epochs` records each published epoch.
- Publishing an epoch is a compare-and-swap: `epoch = current + 1`, and the
  conversation row is updated only when its `key_epoch` still matches. Two
  concurrent creators therefore cannot fork an epoch; the loser re-reads and
  unwraps the winner's key.
- A publish must contain exactly one envelope for every active v2 device of
  both participants. Missing, duplicate, or foreign device ids are rejected.
- A send is rejected with `key_epoch_conflict` when its epoch is not current.
- When a device is revoked, `key_rotation_required` is set on every
  conversation of that account. Sends fail with `key_rotation_required` until
  a new epoch is published without the revoked device.
- After rotation, remaining devices continue to read older messages through the
  locally stored key for the old epoch.

Conversation keys are cached in memory and in secure storage per
`userId + conversationId + epoch`. A missing unwrapped key triggers an envelope
fetch; there is no plaintext or stale-key fallback.

### Device bootstrap and pairing

- `POST /api/devices/v2/register` creates the first conversation-key device
  only when the account has no active device.
- `POST /api/devices/v2/upgrade` converts a legacy (v1) installation in place.
  It is only accepted while the account has **no** active v2 device; after
  that, a silent upgrade is rejected with `pairing_required`.
- Additional installations must be approved by an existing v2 device through
  QR pairing. See [pairing.md](pairing.md).

### Device revocation

`DELETE /api/devices/:id` closes the device's sockets, deletes the device row
(and its pre-keys/envelopes through foreign keys), and marks every conversation
of that account as rotation-required. The next send publishes a new epoch whose
envelopes omit the revoked device. A revoked device cannot receive new
envelopes or messages. It may still hold keys for earlier epochs and therefore
can read messages it already had access to.

### What the server can and cannot do

The Worker can:

- refuse to store or deliver messages (availability),
- observe message timing, sizes, participants, and epoch numbers,
- relay opaque envelopes and pairing proofs.

The Worker cannot:

- derive conversation or wrapping keys,
- decrypt message ciphertext,
- forge a message that authenticates under a conversation key,
- silently substitute pairing keys: the initiator verifies an AEAD proof bound
  to the session, installation id, and joined identity key before approval.

---

## Version 1: Legacy Signal Protocol

The original implementation remains for rows with `encryption_version = 1`.
It uses `libsignal_protocol_dart`:

- X3DH for initial agreement.
- Double Ratchet for subsequent messages.
- AES-256-CBC + HMAC-SHA256 inside the ratchet.
- One ciphertext per recipient device, stored in `message_deliveries`.

V1 rows are still decrypted by `SignalCryptoService`. V1 edit, delete, and
unsend paths remain in place. No new message is written as v1.

### Compatibility rules

- A row is handled as v2 only when `encryption_version == 2` **and** the
  ciphertext, nonce, tag, and epoch fields are present.
- Malformed v2 metadata produces a controlled "not decrypted" state, not a
  plaintext or legacy fallback.
- V1 rows are never passed through the v2 service, and v2 rows are never passed
  through the Double Ratchet.
- Local caches store the version alongside the ciphertext so offline
  restoration picks the same path.

The v1 implementation is preserved on the `archive/signal-e2ee` branch.

---

## Licence

`libsignal_protocol_dart` is licensed under GPL-3.0. Flexiyo is distributed
under AGPL-3.0; linking the two is permitted under GPLv3 section 13.

Under GPL-3.0, distributions must:

1. Make the corresponding complete source code available to recipients under
   the GPL-3.0 or a compatible licence.
2. Include the GPL-3.0 licence text.
3. Preserve all copyright and licence notices.

The `libsignal_protocol_dart` copyright notice must be preserved and included
in distributions. See the upstream LICENSE file:
<https://github.com/MixinNetwork/libsignal_protocol_dart/blob/main/LICENSE>.

---

## Known limitations

- **No per-message forward secrecy within an epoch.** Anyone who obtains a
  conversation key can decrypt every message encrypted under that epoch.
  Rotation limits the window but does not eliminate it.
- **Compromised installation.** An attacker who controls an authorized
  installation and its secure storage can read messages delivered to it. The
  protocol does not provide post-compromise security.
- **Revocation is forward-looking.** Revoking a device cannot erase keys or
  plaintext it already received.
- **Provisioning requires the initiating device.** When a new device pairs, the
  approving device must be online to wrap the current keys for every existing
  conversation. Conversations created after pairing are handled automatically.
- **No independent audit.** The implementation has not been independently
  audited. Do not treat it as a replacement for a reviewed protocol in a
  high-risk deployment.
- **Metadata is visible.** The server sees participants, timestamps, message
  sizes, and epoch numbers. Message content, keys, and pairing secrets are not
  sent to the server.

## Related documents

- [pairing.md](pairing.md) — QR pairing protocol and trust assumptions
- [security.md](security.md) — threat model
- [architecture.md](architecture.md) — components and data flow
