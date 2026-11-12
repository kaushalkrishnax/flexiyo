# QR Device Pairing

Pairing adds a second (or later) installation to an account without sending the
conversation keys, or the secret that protects them, to the server.

## Trust model

- Both installations must be signed in to the same account. The Worker
  authenticates the account JWT; it does not authorize the new installation on
  its own.
- An **existing, active conversation-key device** must create the session and
  approve the new device. Approval is bound to that exact device, not just to
  the account.
- The QR payload contains a one-time 32-byte secret. Anyone who obtains the
  payload before it expires can complete the join step, but the approving
  device verifies the resulting proof before granting access. Treat the QR
  code like a password.
- The server never receives the pairing secret. It relays opaque public keys
  and one AEAD proof.

## Protocol

Notation: `IK` is the joining installation's X25519 identity key, `E` an
ephemeral X25519 key, and `HKDF` is HKDF-SHA256 with 32-byte output.

1. **Create (existing device).**
   - Requires an active v2 device.
   - The client generates an ephemeral X25519 key pair `(e_i, E_i)` and a
     random 32-byte `pairingSecret`.
   - `POST /api/devices/pairing/create` with `E_i`. The server stores a session
     with `initiator_device_id`, `status = pending`, and a 180-second expiry.
   - The client stores `e_i` and `pairingSecret` in secure storage keyed by the
     session id.

2. **Display.**
   - The app renders a QR code whose JSON payload is:
     `{"type":"flexiyo-pairing-v2","sessionId", "initiatorEphemeralPublic": E_i, "pairingSecret", "expiresAt"}`.
   - The payload is also copyable for devices without a camera.

3. **Join (new device).**
   - The device scans or pastes the payload, then generates its identity key
     pair `IK` (if absent) and an ephemeral key pair `(e_j, E_j)`.
   - `S = X25519(e_j, E_i)`.
   - `K = HKDF(S, salt = pairingSecret, info = transcript)`, where the
     transcript is the JSON array
     `["flexiyo-pairing-proof-v2", sessionId, installationId, base64(IK.public)]`.
   - `proof = XChaCha20-Poly1305(K, nonce, challenge, aad = transcript)` with a
     random 32-byte challenge.
   - `POST /api/devices/pairing/:id/join` with `installationId`, `IK.public`,
     `E_j`, `nonce`, `ciphertext`, `tag`. The server does not verify the proof;
     it only stores it for the initiator.
   - The joining device **does not** send or store `pairingSecret`; it only
     reads it from the QR payload.

4. **Verify and approve (existing device).**
   - The initiator polls `GET /api/devices/pairing/:id`.
   - When `status = joined`, it recomputes the shared secret from `e_i` and
     `E_j`, re-derives `K` with the stored `pairingSecret` and the transcript
     from the server response, and decrypts the proof.
   - A proof of the wrong length or a failed AEAD tag aborts approval. The
     initiator never approves on a mismatch.
   - On success it calls `POST /api/devices/pairing/:id/approve`. The server
     creates or promotes the device row atomically and marks the session
     approved.
   - The initiator then wraps the current conversation key, for every existing
     conversation, to the new device identity and uploads the envelopes.

5. **Accept (new device).**
   - The new device polls until `status = approved`, stores the returned device
     id, and calls the v2 upgrade endpoint to verify the registration.
   - It fetches missing envelopes lazily when opening conversations.

## Server rules

- Session creation and approval require an active device with
  `encryption_version = 2`; the approver must be the session's
  `initiator_device_id`.
- Joining requires the same account JWT and an unexpired `pending` session.
- An installation already registered as v2 cannot join again (`409`).
- A legacy v1 row for the same installation is promoted in place rather than
  duplicated, so its device id keeps resolving.
- Sessions expire after 180 seconds. Expired, cancelled, and already-approved
  sessions cannot be approved.
- Sessions are single-use: a second approval returns `409`.
- Only the approved device receives the new envelopes; the envelope upload
  endpoint accepts only the caller's own active v2 devices.

## Failure behavior

| Condition | Result |
|---|---|
| QR expired before scanning | Client rejects locally |
| QR expired before approval | Server returns `404` on approve |
| Proof tag invalid | Initiator refuses to approve |
| Different account scans the code | Server requires the session to belong to the caller (`404`) |
| Different device of the same account approves | `404` — approver must be the initiator |
| Installation already v2 | Join rejected with `409` |
| Session approved twice | Second approval `409` |
| Provisioning fails after approval | Approval stands; the initiator retries provisioning idempotently |

## Limitations

- The approving device must be online at approval time and while wrapping keys
  for existing conversations.
- The protocol authenticates the joining device to the approving device; it
  does not display a comparable safety number. A user who scans an attacker's
  QR code grants that device access. Only scan codes generated on your own
  device.
- The server can deny service during pairing; it cannot silently substitute
  keys without failing the proof check.
- Revoking a paired device blocks future epochs but cannot remove keys the
  device already received.
