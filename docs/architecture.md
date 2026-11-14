# Architecture

## System Components

```
┌─────────────────────────────────────────────────────────────────┐
│                     Flutter Application                          │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌───────────────┐ │
│  │  Screens  │  │ Riverpod │  │ Repos /   │  │ Conversation Crypto │ │
│  │  (UI)     │◄─│ Providers│◄─│ Services  │  │ Service       │ │
│  └──────────┘  └──────────┘  └─────┬─────┘  └───────┬───────┘ │
│                                     │                 │          │
│                              ┌──────▼──────┐  ┌──────▼──────┐  │
│                              │  API Service │  │ ConversationKeyStore  │  │
│                              │  (Dio/HTTP)  │  │ (sqflite +  │  │
│                              └──────┬───────┘  │  sec.storage)│ │
│                              ┌──────▼───────┐  └─────────────┘  │
│                              │SocketService │                    │
│                              │(WebSocket)   │                    │
│                              └──────┬───────┘                   │
└─────────────────────────────────────┼───────────────────────────┘
                                      │ HTTPS + WSS
                                      │
┌─────────────────────────────────────▼───────────────────────────┐
│                    Cloudflare Worker                              │
│  ┌────────────┐  ┌──────────────┐  ┌─────────────────────────┐  │
│  │  itty-     │  │  Middleware  │  │   Route Handlers        │  │
│  │  router    │─►│  auth/cors/  │─►│  auth / users /         │  │
│  │            │  │  rateLimit   │  │  conversations /        │  │
│  └────────────┘  └──────────────┘  │  messages / devices     │  │
│                                     └────────────┬────────────┘  │
│                                                  │               │
│  ┌────────────────────────────────┐  ┌──────────▼────────────┐  │
│  │   Durable Object: ChatRoom     │  │   Cloudflare D1       │  │
│  │   (per-conversation WebSocket  │  │   (SQLite)            │  │
│  │    hub for real-time delivery) │  │                       │  │
│  └────────────────────────────────┘  │  users                │  │
│                                      │  devices                  │  │
│                                      │  conversations            │  │
│                                      │  messages (ciphertext)    │  │
│                                      │  local_deletions          │  │
│                                      │  token_revocations        │  │
│                                      └───────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
flexiyo/
├── lib/                      # Flutter app source
│   ├── app/                  # App widget and router
│   ├── core/                 # Constants, theme, exceptions
│   ├── models/               # Data models
│   ├── services/             # API, WebSocket, conversation-key and ConversationKey services
│   ├── providers/            # Riverpod state
│   ├── screens/              # UI screens (auth, chats, conversation, settings, media)
│   ├── widgets/              # Reusable widgets
│   ├── storage/              # Local DB, secure storage, conversation-key store
│   └── main.dart
├── worker/                   # Cloudflare Worker backend
│   ├── src/
│   │   ├── index.ts          # Worker entry point
│   │   ├── routes/           # API route handlers
│   │   ├── middleware/       # Auth, CORS, rate limiting
│   │   ├── services/         # Business logic
│   │   ├── sockets/          # Durable Object (ChatRoom)
│   │   └── utils/            # JWT, crypto helpers
│   ├── migrations/           # D1 SQL migrations
│   └── tests/                # Backend tests (Vitest)
├── test/                     # Flutter tests
├── docs/                     # Documentation
├── wrangler.toml             # Cloudflare Worker config
├── .env.example              # Required secrets template
└── pubspec.yaml              # Flutter dependencies
```

---

## Data Flow: Sending a Conversation-Key (v2) Message

```
Sender device                   Worker (ChatRoom DO)          Recipient device
     │                             │                              │
     │ 1. Ensure current epoch     │                              │
     │    (unwrap key envelope)    │                              │
     │    Encrypt once with        │                              │
     │    XChaCha20-Poly1305       │                              │
     │    AAD = conversation/message/epoch                         │
     │                             │                              │
     │ 2. WSS send_message         │                              │
     │    {requestId, id,          │                              │
     │     encryptionVersion: 2,   │                              │
     │     ciphertext, nonce,      │                              │
     │     authTag, keyEpoch}      │                              │
     │────────────────────────────►│                              │
     │                             │ 3. Validate auth/device/     │
     │                             │    membership/epoch/rotation │
     │                             │    Idempotent retry check    │
     │                             │ 4. Persist ONE message row   │
     │                             │    to D1; no per-device rows │
     │                             │ 5. Broadcast the SAME        │
     │                             │    ciphertext to authorized  │
     │                             │    v2 devices                │
     │◄──────── 6. ack {ok,id}     │─────────────────────────────►│
     │    (only after D1 persist)  │    {type: new_message,       │
     │                             │     ciphertext, nonce, ...}  │
     │                             │                              │
     │ 7. Mark optimistic message  │              8. Receive event│
     │    sent                     │                 Resolve epoch│
     │                             │                 key, decrypt │
     │                             │                 Display      │
```

The Worker never sees plaintext or conversation keys. It stores and forwards
the ciphertext verbatim; each device obtains the conversation key from its own
`device_key_envelopes` row. A message is marked sent only after the server
`ack`; retries reuse the same message `id` and are idempotent.

---

## Real-Time Delivery: Durable Objects

Each conversation has one **Durable Object** instance (named by conversation ID). It maintains active WebSocket connections for that conversation's participants.

```
HTTP request to Worker
  │
  │  GET /api/ws/:conversationId?token=JWT
  │
  Worker validates JWT
  Worker routes to Durable Object via:
    env.CHAT_ROOM.get(
      env.CHAT_ROOM.idFromName(conversationId)
    ).fetch(request)
  │
  Durable Object upgrades to WebSocket
  Stores session: userId → WebSocket
  │
  On new message (HTTP route handler):
    Worker calls Durable Object:
      /broadcast endpoint with event JSON
    Durable Object delivers to all connected sessions
```

---

## Data Flow: QR Device Pairing

See [pairing.md](pairing.md) for the full protocol.

```
Existing device (A)             Worker                       New device (B)
  │                                │                              │
  │ 1. Generate E_A + pairingSecret│                              │
  │ 2. POST /devices/pairing/create│                              │
  │───────────────────────────────►│ store pending session        │
  │◄───────────────────────────────│ expiresAt                    │
  │ 3. Render QR (secret only in   │                              │
  │    the QR payload)             │                              │
  │                                │   4. Scan / paste QR         │
  │                                │◄─────────────────────────────│
  │                                │   5. POST .../:id/join with  │
  │                                │      E_B + AEAD proof        │
  │ 6. GET .../:id (poll)          │                              │
  │───────────────────────────────►│                              │
  │◄───────────────────────────────│ status=joined + proof        │
  │ 7. Derive shared secret,       │                              │
  │    verify AEAD proof locally   │                              │
  │ 8. POST .../:id/approve        │                              │
  │───────────────────────────────►│ create/promote device        │
  │◄───────────────────────────────│ deviceId                     │
  │ 9. Wrap current keys to B for  │                              │
  │    each conversation           │                              │
  │───────────────────────────────►│ device_key_envelopes         │
  │                                │   10. GET .../:id (poll)     │
  │                                │◄─────────────────────────────│
  │                                │─────────────────────────────►│
  │                                │      11. accept device id    │
```

The pairing secret never reaches the Worker. Approval is restricted to the
device that created the session, and the proof binds the session id,
installation id, and joining identity key.

---

## Local Storage (Flutter)

### sqflite tables

| Table | Purpose |
|---|---|
| `messages` | Cached message records (encrypted + decrypted, with `nonce`, `auth_tag`, `key_epoch`) |
| `conversations` | Cached conversation metadata |

### flutter_secure_storage

Stores:
- JWT access token
- Installation id
- v2 X25519 identity key seed and public key (per account)
- v2 device id (per account)
- Conversation keys per `conversation + epoch`
- Pairing ephemeral seed and secret while a session is pending

---

## Authentication Flow

```
Client                        Worker (D1)
  │                               │
  │  POST /api/auth/register      │
  │  {username, password}         │
  │──────────────────────────────►│
  │                               │ Hash password (PBKDF2)
  │                               │ INSERT user
  │◄──────────────────────────────│
  │  {token, user}                │
  │                               │
  │  POST /api/devices/register   │
  │  {installationId, identityPublicKey}  │ ← Flutter generates keys locally first
  │──────────────────────────────►│
  │                               │ Store public keys only
  │◄──────────────────────────────│
  │  {ok}                         │
```

---

## Message Expiry Architecture

Disappearing timers start on read, never on send:

```
Worker receives POST /conversations/:id/read
  │
  ├── Marks deliveries read and broadcasts the read receipt
  │
  ├── Timer = "disappear immediately"
  │     DELETE messages rows, recompute last_message_at,
  │     broadcast message_deleted, refresh both inboxes
  │
  └── Timer > 0
        SET expires_at = now + timer on the newly read messages

Worker receives GET /conversations/:id/messages
  └── WHERE expires_at IS NULL OR expires_at > unixepoch()
      (never return expired messages, even before cleanup)

Scheduled cleanup (each trigger, throttled to once a minute):
  └── For messages with expires_at <= unixepoch():
        DELETE messages rows, recompute last_message_at,
        broadcast message_deleted, refresh both inboxes

Flutter client:
  ├── Purges locally expired rows on conversation load and when a timer elapses
  ├── Removes messages on message_deleted WebSocket events
  └── Filters expired rows out of local reads
```

---

## D1 Schema Summary

```sql
users                  (id, username, password_hash, email, google_id,
                        email_verified, created_at)
token_revocations      (jti, user_id, expires_at)
devices                (id, user_id, installation_id, status,
                        created_at, last_seen_at, revoked_at,
                        identity_public_key)
conversations          (id, user_a_id, user_b_id, initiated_by_id,
                        request_status, disappearing_timer, created_at,
                        last_message_at, key_epoch, key_rotation_required)
messages               (id, conversation_id, sender_id, sender_device_id,
                        ciphertext, nonce, auth_tag, key_epoch,
                        message_type, reply_to_id, version,
                        is_unsent, created_at, expires_at, edited_at,
                        system_data, reaction, delivered_at, read_at)
conversation_key_epochs(conversation_id, epoch, created_by_device_id,
                        created_at)
device_key_envelopes   (id, conversation_id, epoch, recipient_device_id,
                        sender_device_id, ephemeral_public_key, nonce,
                        ciphertext, mac, created_at)
pairing_sessions       (id, user_id, initiator_device_id,
                        initiator_ephemeral_public, status,
                        joined_installation_id, joined_identity_public,
                        joined_ephemeral_public, joined_nonce,
                        joined_ciphertext, joined_mac, approved_device_id,
                        created_at, expires_at, approved_at)
local_deletions        (id, user_id, message_id, deleted_at)
```

---

## Offline Synchronization

When a client reconnects after being offline:

1. Client calls `GET /conversations` to refresh the conversation list.
2. For each conversation, `GET /conversations/:id/messages?before=lastKnownMessageId` to paginate new messages.
3. Server returns only live (non-expired, non-unsent) messages; the client's local state is reconciled.
4. Local tombstones (is_locally_deleted) are preserved; deleted messages are excluded from display regardless of what the server returns.
5. Messages whose `expires_at` is in the past are filtered out both server-side and client-side.
