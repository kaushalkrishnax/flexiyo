<div align="center">

<img src="assets/images/icon.png" alt="Flexiyo" width="100" height="100" />

# Flexiyo

### A Privacy-First, End-to-End Encrypted Messenger

**Your messages. Your keys. Your conversation, readable only by you and the person you send it to.**

<br/>

<p>
  <a href="https://github.com/kaushalkrishnax/flexiyo/releases"><img src="https://img.shields.io/github/v/release/kaushalkrishnax/flexiyo?label=Release&color=2563EB&style=flat-square" /></a>
  <a href="https://github.com/kaushalkrishnax/flexiyo/releases"><img src="https://img.shields.io/github/downloads/kaushalkrishnax/flexiyo/total?label=Downloads&color=3DDC84&style=flat-square" /></a>
  <a href="https://github.com/kaushalkrishnax/flexiyo"><img src="https://img.shields.io/github/stars/kaushalkrishnax/flexiyo?label=Stars&color=FAFBFC&style=flat-square" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-AGPL--3.0-10B981?style=flat-square" /></a>
</p>

<p>
  <img src="https://img.shields.io/badge/Flutter-02569B?style=flat-square&logo=flutter&logoColor=white" />
  <img src="https://img.shields.io/badge/Dart-0175C2?style=flat-square&logo=dart&logoColor=white" />
  <img src="https://img.shields.io/badge/Signal_Protocol-3A76F0?style=flat-square&logo=signal&logoColor=white" />
  <img src="https://img.shields.io/badge/Cloudflare_Workers-F38020?style=flat-square&logo=cloudflare&logoColor=white" />
  <img src="https://img.shields.io/badge/TypeScript-3178C6?style=flat-square&logo=typescript&logoColor=white" />
  <img src="https://img.shields.io/badge/Android-3DDC84?style=flat-square&logo=android&logoColor=white" />
  <img src="https://img.shields.io/badge/iOS-000000?style=flat-square&logo=apple&logoColor=white" />
</p>

</div>

---

### 📌 Table of Contents

- [⬇ Download](#-download)
- [✨ Highlights](#-highlights)
- [📋 Features](#-features)
- [🔌 Tech](#-tech)
- [🏗 Architecture](#-architecture)
- [🔐 Privacy and Security](#-privacy-and-security)
- [📸 Preview](#-preview)
- [🚀 Quick Start](#-quick-start)
- [⌨ Commands](#-commands)
- [⚙ Environment Variables](#-environment-variables)
- [☁ Deployment](#-deployment)
- [🛠 Troubleshooting](#-troubleshooting)
- [🗺 Roadmap](#-roadmap)
- [📚 Documentation](#-documentation)
- [⚖ Legal Notice](#-legal-notice)
- [License](#license)

---

## ⬇ Download

**Current Version:** `v1.0.1` · Android 7.0+ · iOS builds from source

| Build Variant | Device Compatibility         | Download                                                                                                                                                                                                                   |
| ------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **arm64-v8a** | Modern Android devices       | [![Download arm64-v8a](https://img.shields.io/badge/Download-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/kaushalkrishnax/flexiyo/releases/download/v1.0.1/Flexiyo-1.0.1-arm64-v8a.apk) |
| **armeabi-v7a** | Older Android devices        | [![Download armeabi-v7a](https://img.shields.io/badge/Download-5C6BC0?style=for-the-badge&logo=android&logoColor=white)](https://github.com/kaushalkrishnax/flexiyo/releases/download/v1.0.1/Flexiyo-1.0.1-armeabi-v7a.apk) |
| **x86_64**    | Emulators and x86_64 devices | [![Download x86_64](https://img.shields.io/badge/Download-0288D1?style=for-the-badge&logo=android&logoColor=white)](https://github.com/kaushalkrishnax/flexiyo/releases/download/v1.0.1/Flexiyo-1.0.1-x86_64.apk)       |

> **Quick Guide:** Not sure? Pick **arm64-v8a**, it covers virtually every phone made since 2017. Emulator users should pick **x86_64**. iOS users can build from source, see [Quick Start](#-quick-start).

---

## ✨ Highlights

<div align="center">
  <table>
    <tr>
      <td width="50%" align="center">
      <br/>🔒
      <h3>Encrypted by default</h3>
      <sub>Signal Protocol (X3DH + Double Ratchet) runs on your device. The server only ever sees ciphertext.</sub>
      <br/><br/>
      </td>
      <td width="50%" align="center">
      <br/>⚡
      <h3>Real-time delivery</h3>
      <sub>WebSockets on Cloudflare Durable Objects with offline sync, typing indicators, and low latency.</sub>
      <br/><br/>
      </td>
    </tr>
    <tr>
      <td width="50%" align="center">
      <br/>🫥
      <h3>Control your messages</h3>
      <sub>Edit, unsend for everyone, delete for yourself, or let a per-chat timer make them disappear.</sub>
      <br/><br/>
      </td>
      <td width="50%" align="center">
      <br/>🎨
      <h3>Modern design</h3>
      <sub>Clean, familiar chat UI with Material 3 theming and adaptive light and dark modes.</sub>
      <br/><br/>
      </td>
    </tr>
  </table>
</div>

---

## 📋 Features

### Messaging

- **End-to-end encrypted by design:** Every message is encrypted on the sender's device with the Signal Protocol (X3DH key agreement and Double Ratchet) and decrypted only on the recipient's. The server stores ciphertext it has no way to read.
- **Instant, with offline catch-up:** Each conversation gets its own WebSocket hub on a Durable Object, so delivery and typing indicators are real time. Anything sent while you were away syncs the moment you reconnect.
- **Device-isolated accounts:** Sign up with a username and password. Session tokens live in the platform keychain and stay on the device.

### Control over what you send

- **Edit:** Fix a sent message within the editing window. The edit is re-encrypted on the client, so the server never sees the new text.
- **Unsend for everyone:** Pulls a message from both sides. A tombstone syncs to active participants and the stored payload is deleted from the server.
- **Delete for me:** Clears a message from your device only. The other person's chat is untouched.
- **Disappearing messages:** Set an expiry timer per conversation. The server prunes expired messages and the client filters them out as well, so nothing lingers between cleanup runs.
- **Copy:** One tap copies the decrypted text to the clipboard.

### Media

- **Encrypted photos and voice notes:** Snap a photo, pick one from the gallery, or record a voice note — media is encrypted on-device (AES-GCM) before it leaves your phone, and expired media is purged from the server.
- **View limits:** Mark a photo as view-once or view-twice when sending; the server enforces the limit and refuses further opens once it is used up.

### Experience

- **Familiar, modern chat UI:** Clean responsive layout, Material 3 theming, adaptive light and dark modes, long-press context menus, swipe to reply, and hold-and-swipe to peek at message times.
- **Android notifications:** Firebase Cloud Messaging delivers a heads-up when a message or message request arrives while the app is closed. Notifications only include who sent it — never the message content.
- **One codebase, two platforms:** Flutter for Android and iOS, with Android as the primary test target.

**Note:** Multi-device sync is on the [Roadmap](#-roadmap).

---

## 🔌 Tech

| Area           | Technology                                          |
| -------------- | --------------------------------------------------- |
| Mobile client  | Flutter · Dart                                      |
| State          | Riverpod                                            |
| Routing        | go_router                                           |
| Local storage  | SQLite (`sqflite`) · `flutter_secure_storage`       |
| Cryptography   | `libsignal_protocol_dart` (X3DH, Double Ratchet)    |
| Backend        | Cloudflare Workers · TypeScript · `itty-router`     |
| Database       | Cloudflare D1 (SQLite) · Drizzle ORM                |
| Real-time      | Cloudflare Durable Objects · WebSockets             |
| Validation     | Zod                                                 |
| Backend tests  | Vitest                                              |
| Package mgr    | Bun                                                 |

---

## 🏗 Architecture

```
Flutter (Android / iOS)
        │
        │  HTTPS + WebSocket (WSS)
        ▼
Cloudflare Worker (worker/src/)
        │
        ├── Cloudflare D1 (SQLite)    encrypted message storage
        └── Durable Objects           per-conversation WebSocket hub
```

Messages are encrypted on the sender's device, routed through the Worker, and decrypted only on the recipient's device. Full detail lives in [`docs/architecture.md`](docs/architecture.md).

---

## 🔐 Privacy and Security

Flexiyo is built around zero-knowledge message transport.

| Layer                  | What happens                                                                                              |
| ---------------------- | --------------------------------------------------------------------------------------------------------- |
| **Client cryptography** | Key generation, session negotiation, and encryption all happen on-device.                                |
| **Key storage**         | Private identity and session keys live in hardware-backed storage (iOS Keychain, Android Keystore) and never reach the backend. |
| **Server visibility**   | Public identity keys, prekey bundles, ciphertexts, and operational metadata (delivery timestamps, user IDs). |
| **Server blind spots**  | Message contents. The server cannot decrypt or inspect them.                                              |

> **⚠️ Security boundaries:** E2EE protects content in transit and at rest on the server, but security still depends on device integrity. Compromised devices, screen recordings, and external backups sit outside the protocol. Flexiyo has **not** undergone an independent third-party security audit.

Deeper reading: [`docs/encryption.md`](docs/encryption.md) · [`docs/security.md`](docs/security.md)

---

## 📸 Preview

Screenshots coming soon.

---

## 🚀 Quick Start

### Prerequisites

| Requirement            | Version  | Download                                                |
| ---------------------- | -------- | ------------------------------------------------------- |
| **Flutter**            | ≥ 3.19.0 | [flutter.dev](https://flutter.dev/)                     |
| **Dart**               | ≥ 3.3.0  | Bundled with Flutter                                    |
| **Bun**                | ≥ 1.0.1  | [bun.sh](https://bun.sh/)                               |
| **Wrangler**           | ≥ 4.0.0  | Installed via `bun install`                             |
| **Cloudflare account** | Free tier works | [cloudflare.com](https://www.cloudflare.com/)   |
| **Android Studio**     | Latest   | [developer.android.com](https://developer.android.com/studio) |
| **Xcode** *(iOS only)* | Latest   | Mac App Store                                           |

### 1. Backend

```bash
git clone https://github.com/kaushalkrishnax/flexiyo.git
cd flexiyo

bun install
```

Create the D1 database, then copy the `database_id` from the output into `worker/wrangler.toml` under `[[d1_databases]]`:

```bash
bunx wrangler d1 create flexiyo-db
```

Apply migrations locally:

```bash
bun run db:migrate:local
```

Create a `.dev.vars` file (not committed) with your local secret:

```
JWT_SECRET=your-local-dev-secret-at-least-32-chars
```

Start the Worker:

```bash
bun run dev
```

The Worker is now available at `http://localhost:8787`.

### 2. Flutter app

```bash
flutter pub get
```

Point the app at your Worker with `API_BASE_URL`, using the right address for your target:

| Target                    | Command                                                              |
| ------------------------- | -------------------------------------------------------------------- |
| **Android emulator**      | `flutter run --dart-define=API_BASE_URL=http://localhost:8787` |
| **iOS simulator**         | `flutter run --dart-define=API_BASE_URL=http://localhost:8787`       |
| **Physical device**       | `flutter run --dart-define=API_BASE_URL=http://<your-local-ip>:8787` |

> **💡 Tip:** For a physical device, use your machine's LAN IP (for example `192.168.1.10`) and make sure the phone is on the same network.

---

## ⌨ Commands

| Command                     | Description                                   |
| --------------------------- | --------------------------------------------- |
| `bun install`               | Install JS dependencies                       |
| `bun run dev`               | Start local Worker (Wrangler)                 |
| `bun run test`              | Run backend tests (Vitest)                    |
| `bun run type-check`        | TypeScript type checking                      |
| `bun run db:migrate:local`  | Apply D1 migrations locally                   |
| `bun run db:migrate:remote` | Apply D1 migrations to remote (requires auth) |
| `flutter pub get`           | Install Flutter dependencies                  |
| `flutter test`              | Run Flutter tests                             |
| `flutter analyze`           | Static analysis                               |
| `flutter build apk`         | Build Android APK                             |
| `flutter build ios`         | Build iOS (requires macOS and Xcode)          |

---

## ⚙ Environment Variables

See [`.env.example`](.env.example) for the full template.

| Variable         | Where                   | Description                  |
| ---------------- | ----------------------- | ---------------------------- |
| `JWT_SECRET`     | Wrangler secret         | HS256 signing key for JWTs   |
| `FCM_SERVICE_ACCOUNT` | Wrangler secret    | Firebase service-account JSON for Android push (optional) |
| `D1_DATABASE_ID` | `worker/wrangler.toml`  | Cloudflare D1 database ID    |
| `CORS_ORIGIN`    | `worker/wrangler.toml` vars | Allowed CORS origin      |
| `API_BASE_URL`   | Flutter `--dart-define` | Override API URL for dev     |

---

## ☁ Deployment

> **⚠️ Warning:** Do not deploy without setting all required secrets, and do not run `wrangler deploy` without explicit intent.

```bash
# 1. Set the production secret (from worker/)
cd worker
bunx wrangler secret put JWT_SECRET

# Optional — Android push notifications (Firebase Cloud Messaging):
# paste the service-account JSON when prompted
bunx wrangler secret put FCM_SERVICE_ACCOUNT

# 2. Apply remote migrations and deploy the Worker
bun run db:migrate:remote
bun run deploy

# 3. Build and deploy the web app (from the repo root)
cd ..
bun run build:web && bun run deploy:pages
```

After deploying, build the app against your production URL:

```bash
flutter build apk --dart-define=API_BASE_URL=https://your-worker.workers.dev
```

---

## 🛠 Troubleshooting

<details>
<summary><b>📱 App cannot reach the local Worker</b></summary>

- Android emulator must use `10.0.2.2`, not `localhost`
- Physical devices need your machine's LAN IP and the same Wi-Fi network
- Confirm the Worker is running with `bun run dev`
- Plain HTTP is only for local dev, use HTTPS in production

</details>

<details>
<summary><b>🔔 Push notifications not arriving (Android)</b></summary>

- `FCM_SERVICE_ACCOUNT` must be set as a Wrangler secret: Firebase console → Project settings → Service accounts → Generate new private key, then paste the whole JSON on one line
- The device registers its token when the user signs in — sign in again after installing a new build
- Android 13+ asks for notification permission on first sign-in; if denied, enable it in system settings
- iOS push is not wired up yet (needs `GoogleService-Info.plist` + APNs keys)

</details>

<details>
<summary><b>🔑 Login fails or every request returns 401</b></summary>

1. Check that `.dev.vars` exists and `JWT_SECRET` is at least 32 characters
2. Restart `bun run dev` after changing `.dev.vars`
3. For production, confirm the secret was set with `wrangler secret put JWT_SECRET`

</details>

<details>
<summary><b>🗄️ Database errors or missing tables</b></summary>

- Run `bun run db:migrate:local` for local dev
- Confirm `database_id` in `worker/wrangler.toml` matches the one from `wrangler d1 create`
- For production, run `bun run db:migrate:remote`

</details>

<details>
<summary><b>🔐 Messages fail to decrypt after reinstalling</b></summary>

Private keys live only on the device. Reinstalling or clearing app data removes them, so old sessions cannot be restored. Register the device again to generate fresh keys. Multi-device key sync is on the [Roadmap](#-roadmap).

</details>

<details>
<summary><b>🐘 Build / Gradle issues</b></summary>

```bash
flutter clean
flutter pub get
cd android && ./gradlew clean && cd ..
flutter run
```

</details>

---

## 🗺 Roadmap

- [x] Registration, login, and device-isolated tokens
- [x] Signal Protocol one-to-one E2EE
- [x] Edit, unsend, delete for me, and copy
- [x] Disappearing messages with server-side pruning
- [x] Offline delivery synchronization
- [x] Encrypted photos and voice notes with view limits
- [x] Android push notifications (FCM)
- [ ] iOS and web push notifications
- [ ] Multi-device key synchronization
- [ ] File attachments
- [ ] Expanded platform specific testing
- [ ] Independent security audit

---

## 📚 Documentation

| Document                                        | What it covers                                           |
| ----------------------------------------------- | -------------------------------------------------------- |
| [Architecture Overview](docs/architecture.md)   | System components, data models, WebSocket lifecycle      |
| [Development Guide](docs/development.md)        | Prerequisites, database setup, testing, build workflows  |
| [Encryption Design](docs/encryption.md)         | Signal Protocol integration, ratchets, key replenishment |
| [Security and Threat Model](docs/security.md)   | Security boundaries, trust assumptions, mitigations      |

---

## ⚖ Legal Notice

**Flexiyo is an independent project.** It is not affiliated with, endorsed by, or connected to Signal Messenger LLC (formerly Open Whisper Systems). The Signal Protocol is developed by Signal Messenger LLC, and Flexiyo claims no copyright over it. Flexiyo has not been independently audited, so use it accordingly.

---

## License

**AGPL-3.0** © 2026 Flexiyo · See [LICENSE](LICENSE)

- **User freedom:** Run, study, modify, and distribute Flexiyo for any purpose, including commercial use.
- **Source disclosure:** If you convey a modified version, or run one on a server to offer network services, you must make the complete corresponding source available under AGPL-3.0.
- **Copyleft:** Derivative works must also be licensed under AGPL-3.0 (or compatible terms under Section 13).

### Third-Party Attributions

| Component                 | License       | Notes                                                                                     |
| ------------------------- | ------------- | ----------------------------------------------------------------------------------------- |
| `libsignal_protocol_dart` | GPL-3.0       | © Open Whisper Systems, Mixin Network contributors. Combined under GPLv3 Section 13.      |
| `drizzle-orm`             | Apache-2.0    | Attribution                                                                               |
| `itty-router`             | MIT           | Attribution                                                                               |
| `zod`                     | MIT           | Attribution                                                                               |
| `flutter_riverpod`        | MIT           | Attribution                                                                               |
| `go_router`               | BSD-3-Clause  | Attribution                                                                               |
| `flutter_secure_storage`  | BSD-3-Clause  | Attribution                                                                               |
| `sqflite`                 | BSD-2-Clause  | Attribution                                                                               |

See [`docs/encryption.md`](docs/encryption.md) for the full GPL compliance discussion.

---