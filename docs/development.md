# Development Guide

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Flutter | ≥ 3.19.0 | https://docs.flutter.dev/get-started/install |
| Dart | ≥ 3.3.0 | Included with Flutter |
| Bun | ≥ 1.0.0 | `curl -fsSL https://bun.sh/install \| bash` |
| Wrangler | ≥ 4.0.0 | `bun add -g wrangler` |
| Cloudflare account | — | https://dash.cloudflare.com/sign-up |

---

## First-Time Setup

### 1. Install JS dependencies

```bash
bun install
```

### 2. Create the D1 database (once)

```bash
bunx wrangler d1 create flexiyo-db
```

Paste the `database_id` into `wrangler.toml`:

```toml
[[d1_databases]]
binding = "DB"
database_name = "flexiyo-db"
database_id = "PASTE_HERE"  # ← replace this
migrations_dir = "worker/migrations"
```

### 3. Apply local migrations

```bash
bun run db:migrate:local
```

### 4. Create local dev secrets file

Create `.dev.vars` at the repository root (not committed):

```
JWT_SECRET=dev-local-secret-at-least-32-characters-long
CORS_ORIGIN=http://localhost:8787
```

### 5. Start the Worker development server

```bash
bun run dev
# → http://localhost:8787
```

### 6. Install Flutter dependencies

```bash
flutter pub get
```

---

## Environment Variables

See [`.env.example`](../.env.example) for the complete secrets template.

| Variable | Target Location | Description |
|---|---|---|
| `JWT_SECRET` | `.dev.vars` (local) / Wrangler secret (prod) | HS256 secret key for signing auth tokens |
| `D1_DATABASE_ID` | `wrangler.toml` (`database_id`) | Cloudflare D1 database UUID |
| `CORS_ORIGIN` | `wrangler.toml` (`[vars]`) | Allowed CORS origin |
| `API_BASE_URL` | Flutter `--dart-define` | API base URL for mobile devices |

---

## Common Commands

| Task | Command | Description |
|---|---|---|
| Dependencies | `bun install` | Install backend JS/TS dependencies |
| Backend Dev | `bun run dev` | Start local Worker dev server via Wrangler |
| Backend Tests | `bun run test` | Run Vitest suite for Workers API |
| Backend Types | `bun run type-check` | Run TypeScript compiler checks |
| Local DB Migrate | `bun run db:migrate:local` | Apply D1 SQL migrations locally |
| Remote DB Migrate | `bun run db:migrate:remote` | Apply D1 SQL migrations to remote D1 |
| Flutter Deps | `flutter pub get` | Install Flutter package dependencies |
| Flutter Tests | `flutter test` | Run client unit and widget test suite |
| Flutter Analysis | `flutter analyze` | Run Dart analyzer static checks |
| Build APK | `flutter build apk --release` | Compile production Android APK |
| Build iOS | `flutter build ios --release` | Compile iOS bundle (macOS + Xcode) |

## Running Tests

### Backend (Vitest)

```bash
bun run test
# or in watch mode:
bun run test:watch
```

### TypeScript type check

```bash
bun run type-check
```

### Flutter

```bash
flutter test
```

### Flutter analysis

```bash
flutter analyze
```

---

## Running the Flutter App

### Android emulator

The Android emulator uses `10.0.2.2` to reach the host's localhost:

```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8787
```

### iOS simulator

```bash
flutter run --dart-define=API_BASE_URL=http://localhost:8787
```

### Physical Android device

Find your machine's local IP address:

```bash
# macOS
ipconfig getifaddr en0
```

Then:

```bash
flutter run --dart-define=API_BASE_URL=http://192.168.X.X:8787
```

The device and machine must be on the same network.

### Physical iOS device

Same as Android — use your machine's LAN IP address.

Note: iOS requires the local server to use HTTPS or be listed in `NSAppTransportSecurity` exemptions in `Info.plist`. For local dev without TLS, add:

```xml
<!-- ios/Runner/Info.plist (dev only — remove for production) -->
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key>
  <true/>
</dict>
```

---

## Building

### Android

Create a release keystore once and keep it backed up securely. The keystore
certificate must remain the same for every future APK or Android will reject
updates over an existing installation.

```bash
keytool -genkeypair -v \
  -keystore android/upload-keystore.jks \
  -alias upload \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000
cp android/key.properties.example android/key.properties
```

Replace every placeholder in `android/key.properties` with the values used for
the keystore. `key.properties` and `*.jks` are ignored by Git. Do not commit
either file or its passwords.

```bash
flutter build apk --release
# APK at: build/app/outputs/flutter-apk/app-release.apk
```

Or split per ABI:

```bash
flutter build apk --split-per-abi --release
```

### iOS

Requires macOS with Xcode installed:

```bash
flutter build ios --release
```

Then open Xcode and archive for distribution.

---

## Database Operations

### Apply local migrations

```bash
bunx wrangler d1 migrations apply flexiyo-db --local
```

### Apply remote migrations

```bash
bunx wrangler d1 migrations apply flexiyo-db --remote
```

⚠️ This modifies the **production** D1 database. Only run with intent.

### Inspect local D1

```bash
bunx wrangler d1 execute flexiyo-db --local --command "SELECT * FROM users LIMIT 10"
```

### Create a new migration

Create a numbered file in `worker/migrations/`:

```bash
# e.g., worker/migrations/0003_add_column.sql
```

Wrangler applies migrations in filename order.

---

## Wrangler Authentication

To deploy or apply remote migrations, log in first:

```bash
bunx wrangler login
```

This opens a browser for OAuth with your Cloudflare account.

---

## Deploying to Production

> ⚠️ Only deploy after all tests pass and secrets are set.

```bash
# 1. Set JWT secret (prompted interactively)
bunx wrangler secret put JWT_SECRET

# 2. Apply migrations to remote D1
bun run db:migrate:remote

# 3. Deploy Worker
bunx wrangler deploy
```

The Worker will be live at `https://flexiyo.kaushalkrishnax.workers.dev`.

---

## Troubleshooting

### `wrangler: command not found`

Ensure `~/.bun/bin` is in your PATH, or use `bunx wrangler`.

### D1 `database_id` is a placeholder

You need to run `bunx wrangler d1 create flexiyo-db` and paste the real ID into `wrangler.toml`.

### JWT_SECRET not set

Create `.dev.vars` at the root with `JWT_SECRET=...` for local development.

### Flutter `pub get` fails on libsignal_protocol_dart

Ensure Flutter SDK is ≥ 3.19.0 and Dart is ≥ 3.3.0:

```bash
flutter --version
dart --version
```

### WebSocket connection fails

Check that:
1. The Worker dev server is running (`bun run dev`)
2. `API_BASE_URL` is set correctly for your device type
3. The Durable Object class `ChatRoom` is exported from `worker/src/index.ts`

### Message decryption fails after reinstall

Signal Protocol session state is stored in the local sqflite database. After reinstalling the app (clearing local storage), all sessions are lost. You must re-register a device:
- The app will automatically regenerate keys and re-register on first login after reinstall.
- Old sessions with other users will be broken until they send you a new message (which re-establishes the session).

### Pre-key exhausted (503 from key-bundle endpoint)

The server has no more one-time pre-keys for a user. The Flutter client should detect low pre-key count and replenish:

```dart
// Check count after login
final count = await api.getPreKeyCount();
if (count < 10) {
  await keyManager.replenishPreKeys(store, api);
}
```

---

## Code Conventions

- **Dart**: Follow `flutter analyze` (no warnings)
- **TypeScript**: `strict: true`, no `any` without justification
- **SQL**: Prepared statements only, no string interpolation
- **Naming**: camelCase for variables/functions, PascalCase for classes, snake_case for DB columns
- **Indentation**: 2 spaces (TypeScript), 2 spaces (Dart)
- **Comments**: Explain *why*, not *what*

---

## Project Linting

```bash
# TypeScript
bun run type-check

# Flutter
flutter analyze
flutter format --set-exit-if-changed lib/
```
