# TicTac Integration: Hooks & Callbacks

One paradigm: callbacks. TicTac holds no chat state — every event
fires through a [TicTacCallbacks] bag with the relevant data passed
as arguments. The caller (or the bundled `TicTacChat` widget) keeps
whatever state it wants to display.

Wire-up order: **configure → connect → join topic → send/render →
start voice**.

For overall architecture see `README.md`. For migration notes
(2.x → 3.x) see `CHANGELOG.md`.

---

## TL;DR — minimum viable text chat

```dart
final tictac = TicTacModule(
  TicTacConfig(
    tinodeHost: cfg.tinodeHost,
    tinodePort: cfg.tinodePort,
    appUserId:  userManager.userId,
    appId:      cfg.appId,
    appKey:     cfg.appKey,
    sessionId:  const Uuid().v4(),
    generateRequestId: () => const Uuid().v4(),
    authTokenProvider: () => firebase.idToken,
    resolveAppUserId:  (tinodeUid) async => myCache[tinodeUid],
    // voice only — drop entirely if you don't use voice
    mintVoiceToken:    (topicId) => host.mintLiveKitToken(topicId),
  ),
  TicTacCallbacks(
    onConnected:    (topics) => onReady(topics),
    onDisconnected: (reason) => onLost(reason),
  ),
);
await tictac.connect();
```

That gets you a connected module. For a working chat UI, drop in:

```dart
TicTacChat(module: tictac, topicId: topicId)
```

— no other wiring needed. The widget registers its own callbacks on
the module for the events it needs (messages, members, presence,
typing) and renders via `flutter_chat_ui`.

To customize or skin, pass any `flutter_chat_ui` [Chat] prop to
`TicTacChat` (theme, builders, options) — they all forward.

---

## 1. `TicTacConfig` — callbacks-as-fields

| Field | When called | Notes |
|---|---|---|
| `generateRequestId` | per outbound packet | UUID v4 is fine. |
| `authTokenProvider` | every `connect()` / `reconnect()` | Returns the Tinode websocket auth token. Return the **fresh** value — don't cache. Null skips the Authorization header. |
| `resolveAppUserId(tinodeUid)` | every message / presence / typing / member event from an unknown user | Tinode UIDs in, app user ids out. Return null → drop the event. TicTac does not cache — wrap with a `Map`-backed cache if you want one. |
| `mintVoiceToken(topicId)` | per `joinVoice(...)` | **Voice only** — omit entirely if you don't use voice. Returns a `VoiceToken { accessToken, livekitUrl, room }`. Host owns the HTTP roundtrip to whatever mint endpoint it runs; tictac doesn't know about TAGS, Lambda, or Firebase. |

### Example `mintVoiceToken` (BonkersClient pattern)

```dart
mintVoiceToken: (topicId) async {
  final resp = await http.post(
    Uri.parse('$tagsBaseUrl/voice/token'),
    headers: {
      'content-type': 'application/json',
      'authorization': 'Bearer ${await firebase.idToken}',
      'x-app-id': appId,
      'x-app-key': appKey,
    },
    body: jsonEncode({'topic_id': topicId, 'app_user_id': appUserId}),
  );
  if (resp.statusCode != 200) {
    throw VoiceTokenException(statusCode: resp.statusCode, body: resp.body);
  }
  final body = jsonDecode(resp.body);
  return VoiceToken(
    accessToken: body['token'],
    livekitUrl:  body['livekit_url'],
    room:        body['room'],
  );
},
```

---

## 2. `TicTacCallbacks` — every event

Pass to the module constructor or register more bags at runtime with
`module.addCallbacks(...)` / `module.removeCallbacks(...)`. Multiple
bags are supported — the module fans out every event to all of them.

### Connection

| Callback | Fires | Carries |
|---|---|---|
| `onConnected(topics)` | auth + heartbeat up; refires after every auto-reconnect | `List<Topic>` — current subscriptions |
| `onDisconnected(reason)` | drop, or terminal-fail after ~7 min of reconnect retries | reason string |

### Topics

| Callback | Fires |
|---|---|
| `onTopicAdded(topic)` | a new subscription appeared (you accepted an invite, a friend added you) |
| `onTopicRemoved(topicId, reason)` | subscription gone |
| `onTopicUpdated(topic)` | metadata changed (name, desc) |

### Messages — global, across every joined topic

| Callback | Fires |
|---|---|
| `onMessageReceived(topicId, message)` | every incoming + every cached message replayed on `joinTopic` + your own send echo |
| `onMessageDeleted(topicId, messageId)` | server confirmed a delete |

The caller dedupes by `message.id`. For optimistic-send → echo, you
insert your placeholder with a client-generated id and replace it on
the echo (the echo's `message.id` is the server seq, different from
your client id — match by author + status, FIFO).

### Per-topic state

| Callback | Fires |
|---|---|
| `onMemberAdded(topicId, member)` | new sub member; also fires for each existing member on `joinTopic` |
| `onMemberRemoved(topicId, appUserId)` | member left/kicked |
| `onTopicPresenceChanged(topicId, appUserId, isOnline)` | per-topic on/off |
| `onUserPresenceChanged(appUserId, isOnline)` | global on/off from the user's me-topic |
| `onTypingStarted(topicId, appUserId)` | keystroke arrived — protocol has no "stopped typing", caller times it out (3s is conventional) |
| `onMessageRead(topicId, appUserId, seq)` | a peer read up to `seq` (inclusive; read markers are cumulative) — mark your own messages with id `<= seq` as seen. Fires live and once on join from the peer's subscription. Peers only, not your own reads. |

---

## 3. `TopicHandle` — methods-only

```dart
final topic = await tictac.joinTopic(topicId);
await topic.sendText('hi');
await topic.sendCustom('GameRequest', {'gameId': 'Chess'}, fallbackText: '...');
await topic.markRead(messageId);
await topic.setTyping(true);              // false is a no-op
await topic.deleteMessage(messageId);
await topic.leave();
```

No `messages`, `members`, `presence` properties — those are events
delivered via `TicTacCallbacks`. The handle exists only to send / leave.

### What lands where, on join

`joinTopic` returns once Tinode acks the subscription. Before the
future resolves, the module starts firing:

- `onMemberAdded` — once per existing member (the roster)
- `onMessageReceived` — once per cached message in history
- `onTopicPresenceChanged` — once per online member

After resolve, the same callbacks fire on live updates.

---

## 4. Message types — where each one lands

| Wire kind | Surfaces as | Type the host sees |
|---|---|---|
| Text message | `onMessageReceived` | `types.TextMessage` |
| Custom (any `customType` payload) | `onMessageReceived` | `types.CustomMessage`, `metadata['customType']` set |
| Typing indicator | `onTypingStarted` | `(topicId, appUserId)` |
| Presence on/off (per topic) | `onTopicPresenceChanged` | `(topicId, appUserId, bool)` |
| Presence on/off (global me-topic) | `onUserPresenceChanged` | `(appUserId, bool)` |
| Member subscription change | `onMemberAdded` / `onMemberRemoved` | `types.User` |
| Message delete | `onMessageDeleted` | `(topicId, String messageId)` |
| Voice participant events | `VoiceCallbacks` (separate bag) | `VoiceParticipant` |
| Read receipt | `onMessageRead` | `(topicId, appUserId, int seq)` |
| Delivered (`recv`) receipt | not surfaced | — |
| Tinode system / control | reflected in member / presence callbacks | no `SystemMessage` type emitted |

### Custom messages — send + render

**Send** — `TopicHandle.sendCustom` from anywhere:

```dart
await topic.sendCustom(
  'GameRequest',
  {'gameId': 'Chess', 'gameName': 'Chess'},
  fallbackText: 'Game request: Chess',
);
```

**Render**, widget path — pass `customMessageBuilder:` to `TicTacChat`
(it's a `flutter_chat_ui` pass-through prop). The widget forwards it
into the `Chat` widget; flutter_chat_ui invokes it for every
`types.CustomMessage` in the list:

```dart
TicTacChat(
  module: tictac,
  topicId: topicId,
  customMessageBuilder: _buildCustomMessage,   // <-- here
)

Widget _buildCustomMessage(
  types.CustomMessage msg, {
  required int messageWidth,
}) {
  switch (msg.metadata?['customType'] as String?) {
    case 'GameRequest':   return GameRequestWidget(msg);
    case 'GameChallenge': return GameChallengeWidget(msg);
    default:
      return Text(msg.metadata?['fallbackText'] ?? '[unknown]');
  }
}
```

**Render**, custom-UI path (no `TicTacChat`) — there's no builder; you
dispatch inside your `onMessageReceived` handler when you accumulate
messages into your own state:

```dart
TicTacCallbacks(
  onMessageReceived: (topicId, msg) {
    if (msg is types.CustomMessage) {
      // route on msg.metadata?['customType'] before / after storing it.
    }
    myMessageStore.upsert(topicId, msg);
  },
)
```

`customType` strings are app-level. TicTac doesn't validate them. Keep
names stable; old clients see unknown types as `fallbackText`.

---

## 5. `TicTacChat` — drop-in widget

```dart
TicTacChat(module: tictac, topicId: topicId)
```

That alone gives you:

- Message list (text + custom)
- Optimistic send → server echo swap
- Typing dots (3s auto-clear)
- Avatars with presence dots
- Auto `markRead` on visibility
- "Seen" status on your messages when a peer reads them
- Send bar with debounced typing notifications

Three customization tiers:

| Tier | What to pass | Example |
|---|---|---|
| Default | nothing extra | `TicTacChat(module: t, topicId: id)` |
| Override per element | any `flutter_chat_ui` [Chat] prop | `theme: customTheme`, `customMessageBuilder: ...`, `customBottomWidget: myInputBar`, `bubbleBuilder: ...`, `avatarBuilder: ...` |
| Full custom UI | ignore `TicTacChat`, wire `addCallbacks` yourself | build your own chat from `onMessageReceived` etc. |

All flutter_chat_ui hooks pass through: `customMessageBuilder`,
`customBottomWidget`, `bubbleBuilder`, `avatarBuilder`,
`textMessageBuilder`, `imageMessageBuilder`, `dateHeaderBuilder`,
`emptyState`, `typingIndicatorOptions`, `inputOptions`,
`onAvatarTap`, `onMessageLongPress`, etc.

---

## 6. Voice — `VoiceCallbacks` + `VoiceSession`

```dart
final session = await tictac.joinVoice(
  topicId,
  voiceCallbacks: VoiceCallbacks(
    onParticipantJoined: (p) => roster.add(p),
    onParticipantLeft:   (p) => roster.removeWhere((x) => x.appUserId == p.appUserId),
    onSpeakingChanged:   (p) => updateSpeakingRing(p),
    onMuteChanged:       (p) => updateMuteIcon(p),
    onSessionEnded:      (reason) => closeCallUI(reason),
  ),
);

await session.mute(true);
await session.leave();
```

Same shape as `TicTacCallbacks`: each event = its own callback,
data on the participant.

---

## What you do NOT wire

- **Reconnect** — built in, ~7 min of backoff before terminal `onDisconnected`.
- **Text-chat token refresh** — `authTokenProvider` is re-called on every reconnect; return fresh.
- **Voice token refresh** — pending (`BNK-531`). 1h TTL today.
- **Identity caching** — your `resolveAppUserId` decides. Wrap in a Map if you want one.
