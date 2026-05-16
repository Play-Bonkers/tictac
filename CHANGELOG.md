# Changelog

## 3.0.0 — Stateless callbacks (BREAKING)

Hard rewrite of the consumer-facing surface. TicTac is now a pure
event-driven transport adapter: it owns the Tinode socket and the
LiveKit room, fires callbacks for every event, and holds **no chat
state**. Hosts (or the bundled `TicTacChat` widget) accumulate
messages, members, presence, and typing in their own state model.

### Why

The v2 API mixed three paradigms (constructor callbacks, ChangeNotifier,
Stream), shipped dead hooks (`onMessageReceived`, `onTopicAdded/Removed/
Updated` were declared but never fired), and forced duplicate identity
fallbacks at two layers. v3 collapses everything onto one paradigm
(callbacks) and removes the dead hooks.

### Added

- `TicTacCallbacks` — single bag of event handlers covering connection,
  topics, messages, members, presence, and typing.
- `TicTacModule.addCallbacks` / `removeCallbacks` — multi-listener
  fan-out. Widgets can layer their own callbacks on top of the host's.
- `TopicHandle` — methods-only handle returned by `joinTopic` (send,
  markRead, setTyping, deleteMessage, leave). No state, no streams.
- `VoiceCallbacks` — per-event callbacks for `VoiceSession`
  (`onParticipantJoined`, `onSpeakingChanged`, `onMuteChanged`, etc.)
  passed to `joinVoice`.
- `TicTacConfig.resolveAppUserId` — single host-supplied callback for
  Tinode UID → app user id resolution. TicTac does not cache; wrap your
  implementation if you want caching.
- `INTEGRATION.md` — full integration guide for the new surface.

### Changed (BREAKING)

- `TicTacModule` constructor signature now `TicTacModule(config, [callbacks])`.
  All event callbacks moved from named module-constructor params into
  `TicTacCallbacks`.
- `joinTopic(topicId)` returns `Future<TopicHandle>` (was
  `Future<TopicController>`).
- `VoiceModule.joinVoice(topicId, callbacks)` now takes a
  `VoiceCallbacks` instead of returning a session with a
  `participantUpdates` Stream.
- `TicTacChat` constructor takes `module` + `topicId` instead of a
  `TopicController`. Internally registers `addCallbacks` to drive its
  own state model.

### Removed (BREAKING)

- `TopicController` — replaced by `TopicHandle`. Per-topic state
  (messages, memberMap, presenceMap, typingUsers) is the caller's
  responsibility.
- `IdentityResolver`, `CachedIdentityResolver`, `TagsIdentityResolver`
  classes. Replaced by the single `TicTacConfig.resolveAppUserId`
  callback. If you need caching or a TAILS-backed lookup, wrap your
  implementation in the host code.
- `VoiceSession.participantUpdates` Stream — events fire on
  `VoiceCallbacks` callbacks instead.
- `VoiceParticipantEvent` enum — the per-event meaning is now encoded
  by which callback fired, not a field on the participant.
- The four module-level `onUnresolvedX` callbacks — `resolveAppUserId`
  returning null is the single signal.

### Migration

For a typical text-chat consumer:

```dart
// Before (v2)
final tictac = TicTacModule(
  TicTacConfig(...),
  onConnected: ..., onDisconnected: ...,
  onPresenceChanged: ..., onMessageReceived: ...,
  onUnresolvedMessageAuthor: ..., // ... 3 more
);
final controller = await tictac.joinTopic(id);
controller.addListener(() {
  // read controller.messages, controller.typingUsers, etc.
});

// After (v3)
final tictac = TicTacModule(
  TicTacConfig(
    ...,
    resolveAppUserId: (tinodeUid) async => myCache[tinodeUid],
  ),
  TicTacCallbacks(
    onConnected: ..., onDisconnected: ...,
    onMessageReceived: (topicId, msg) { /* store / dedupe */ },
    onTopicPresenceChanged: ..., onTypingStarted: ...,
    // ... per-event callbacks for what you care about
  ),
);
final topic = await tictac.joinTopic(id);
await topic.sendText('hi');
```

For widget consumers, `TicTacChat` does all the state work internally:

```dart
TicTacChat(module: tictac, topicId: id)
```

Drop in — works by default. Pass any `flutter_chat_ui` `Chat` prop
(theme, builders, options) to skin or override per element.

See `INTEGRATION.md` for the full guide.

---

## 2.0.x and earlier

See git history.
