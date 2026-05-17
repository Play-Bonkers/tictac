# TicTac

**Torpedo Internal Component for Text and Audio Chat**

Flutter chat library that connects directly to Tinode over websocket, with an abstraction layer that isolates consumers from Tinode internals.

## Architecture (v3)

```
Host app
  └─ package:tictac
       ├─ TicTacModule      (connection, auth, reconnect; stateless)
       ├─ TicTacCallbacks   (one bag, every event; host registers 1..N)
       ├─ TopicHandle       (methods-only handle; no state)
       ├─ TicTacChat        (opt-in widget; wraps flutter_chat_ui;
       │                     owns its own state model internally)
       ├─ VoiceSession      (LiveKit room; fires VoiceCallbacks)
       └─ models/           (own types -- no Tinode leakage)
                ↓ websocket
           Tinode Server
                ↓ REST auth
           Lambda -> TAILS
```

**Stateless on the chat side.** TicTac holds no message list, no
member map, no presence cache. Every event is a callback with the
relevant data on the arguments; the host (or the bundled `TicTacChat`
widget) accumulates whatever it wants to display. See
`INTEGRATION.md` for the wiring guide.

## Auth Flow

1. Client calls `login("rest", protobuf-encoded RestAuthSecret)`
2. Tinode REST auth plugin forwards to Lambda -> TAILS
3. Returns Tinode token (14-day expiry) + tinode user ID
4. Subsequent reconnects use `loginToken(cachedToken)`

## Key Design Rules

- **No Tinode types exposed** to consuming apps -- tictac defines its own model classes.
- **No retained chat state in tictac.** All events flow through callbacks; hosts own the state.
- **Identity resolution is a single host callback** (`TicTacConfig.resolveAppUserId`). TicTac calls it on every Tinode UID it can't map. Wrap with a `Map` cache if you want caching — tictac doesn't.

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
