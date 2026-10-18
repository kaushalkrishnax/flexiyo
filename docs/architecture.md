# Architecture

## System Components

```
┌─────────────────────────────────────────────────────────────────┐
│                     Flutter Application                          │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌───────────────┐ │
│  │  Screens  │  │ Riverpod │  │ Repos /   │  │ Signal Crypto │ │
│  │  (UI)     │◄─│ Providers│◄─│ Services  │  │ Service       │ │
│  └──────────┘  └──────────┘  └─────┬─────┘  └───────┬───────┘ │
│                                     │                 │          │
│                              ┌──────▼──────┐  ┌──────▼──────┐  │
│                              │  API Service │  │ SignalStore  │  │
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
│                                      │  devices              │  │
│                                      │  pre_keys             │  │
│                                      │  conversations        │  │
│                                      │  messages (ciphertext)│  │
│                                      │  local_deletions      │  │
│                                      │  message_delivery     │  │
│                                      │  token_revocations    │  │
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
│   ├── services/             # API and WebSocket services
│   ├── repositories/         # Data access layer
│   ├── providers/            # Riverpod state
│   ├── screens/              # UI screens
│   ├── widgets/              # Reusable widgets
│   ├── crypto/               # Signal Protocol integration
│   ├── storage/              # Local DB and secure storage
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

## Data Flow: Sending a Message

```
Sender device                   Worker (ChatRoom DO)          Recipient device
     │                             │                              │
     │ 1. Compose plaintext        │                              │
     │    Encrypt with Signal      │                              │
     │    (one ciphertext per      │                              │
     │     active recipient device │                              │
     │     + sender's own devices) │                              │
     │                             │                              │
     │ 2. WSS send_message         │                              │
     │    {requestId, id,          │                              │
     │     payloads, ...}          │                              │
     │────────────────────────────►│                              │
     │                             │ 3. Validate auth/session     │
     │                             │    Validate membership,      │
     │                             │    device, payloads, rate    │
     │                             │    Idempotent retry check    │
     │                             │ 4. Persist message +         │
     │                             │    per-device deliveries to  │
     │                             │    D1                        │
     │                             │ 5. Durable Object broadcast  │
     │                             │    new_message (per-device   │
     │                             │    ciphertexts)              │
     │◄──────── 6. ack {ok,id}     │─────────────────────────────►│
     │    (only after D1 persist)  │    {type: new_message,       │
     │                             │     payloads}                │
     │                             │                              │
     │ 7. Mark optimistic message  │              8. Receive event│
     │    sent                     │                 Decrypt with │
     │                             │                 SessionCipher│
     │                             │                 Display      │
```

The Worker never sees plaintext. It stores and forwards the encrypted payload verbatim. A message is marked sent only after the server `ack`; retries reuse the same message `id` and are idempotent.

---

## Data Flow: Session Establishment (X3DH)

```
Alice                             Worker                      Bob
  │                                  │                          │
  │  (Bob registered earlier:        │                          │
  │   Bob's key bundle is in D1)     │                          │
  │                                  │                          │
  │  GET /devices/bob/key-bundle     │                          │
  │─────────────────────────────────►│                          │
  │◄─────────────────────────────────│                          │
  │  {identityKey, signedPreKey,     │                          │
  │   oneTimePreKey}                 │                          │
  │                                  │                          │
  │  X3DH locally                    │                          │
  │  Build session with Bob          │                          │
  │  Encrypt first message           │                          │
  │  (PreKeySignalMessage)           │                          │
  │                                  │                          │
  │  POST /conversations/:id/messages│                          │
  │  {encryptedPayload, type:prekey} │                          │
  │─────────────────────────────────►│                          │
  │                                  │  Store + broadcast       │
  │                                  │─────────────────────────►│
  │                                  │                 Receive  │
  │                                  │                 decryptPreKeyWhisperMessage
  │                                  │                 Session established
  │                                  │                 Display plaintext
```

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

## Local Storage (Flutter)

### sqflite tables

| Table | Purpose |
|---|---|
| `messages` | Cached message records (encrypted + decrypted) |
| `conversations` | Cached conversation metadata |
| `signal_sessions` | Double Ratchet session state |

### flutter_secure_storage

Stores:
- JWT access token
- Signal identity key pair (serialized)
- Signed pre-key pair (serialized)
- One-time pre-key pairs (serialized)
- Registration ID

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
  │  {identityKey, preKeys, ...}  │ ← Flutter generates keys locally first
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
users                  (id, username, password_hash, created_at)
token_revocations      (jti, user_id, expires_at)
devices                (id, user_id, device_id, registration_id, identity_key,
                        signed_pre_key_id, signed_pre_key_public,
                        signed_pre_key_signature, created_at)
pre_keys               (id, user_id, key_id, public_key, used, created_at)
conversations          (id, user_a_id, user_b_id, disappearing_timer,
                        created_at, last_message_at)
messages               (id, conversation_id, sender_id, encrypted_payload,
                        message_type, version, is_unsent, created_at,
                        expires_at, edited_at, system_data)
local_deletions        (id, user_id, message_id, deleted_at)
message_delivery       (id, message_id, recipient_id, delivered_at)
```

---

## Offline Synchronization

When a client reconnects after being offline:

1. Client calls `GET /conversations` to refresh the conversation list.
2. For each conversation, `GET /conversations/:id/messages?before=lastKnownMessageId` to paginate new messages.
3. Server returns only live (non-expired, non-unsent) messages; the client's local state is reconciled.
4. Local tombstones (is_locally_deleted) are preserved; deleted messages are excluded from display regardless of what the server returns.
5. Messages whose `expires_at` is in the past are filtered out both server-side and client-side.
