# TicTac

**Torpedo Internal Component for Text and Audio Chat**

Flutter chat library that connects directly to Tinode over websocket, with an abstraction layer that isolates consumers from Tinode internals.

## Architecture

```
Bonkers App
  └─ TicTacBridge (app-specific integration)
       └─ package:tictac
            ├─ TicTacModule      (connection, auth, reconnect)
            ├─ TopicController   (per-topic state, ChangeNotifier)
            ├─ TicTacChat        (wraps flutter_chat_ui)
            ├─ models/           (own types -- no Tinode leakage)
            └─ identity/         (app_user_id <-> tinode_user_id mapping)
                    ↓ websocket
               Tinode Server
                    ↓ REST auth
               Lambda -> TAILS
```

## Auth Flow

1. Client calls `login("rest", protobuf-encoded RestAuthSecret)`
2. Tinode REST auth plugin forwards to Lambda -> TAILS
3. Returns Tinode token (14-day expiry) + tinode user ID
4. Subsequent reconnects use `loginToken(cachedToken)`

## Key Design Rules

- **No Tinode types exposed** to consuming apps -- tictac defines its own model classes
- **IdentityResolver** abstraction for app_user_id <-> tinode_user_id mapping
- Phase 1: `CachedIdentityResolver` (seeded from auth + topic membership)
- Phase 2: `TagsIdentityResolver` (calls TAILS via TAGS ALB)

## Development

```bash
# Install dependencies
dart pub get

# Run unit tests
dart test test/models/ test/services/

# Run smoke tests (requires Tinode dev server)
dart test test/smoke/
```

## Origin

Forked from [tinode/dart-sdk](https://github.com/tinode/dart-sdk) (archived Nov 2025). GetIt dependency removed, package renamed, Dart 3 compatible.
