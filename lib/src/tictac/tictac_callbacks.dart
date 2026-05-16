import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import 'package:tictac/src/tictac/models/topic.dart';

/// Every TicTac event surfaces as a callback in this bag. Pass an instance
/// to [TicTacModule]'s constructor.
///
/// **Design rule.** TicTac holds no chat state: the caller is responsible
/// for storing messages, members, presence, typing — anything it wants to
/// display. Each callback carries everything needed for the corresponding
/// event; the module never asks "what was the previous value?" or re-emits
/// from a cache. If you need state, accumulate it in your own listener.
///
/// Default-working chat UI: drop in `TicTacChat`, which registers these
/// callbacks internally and renders via `flutter_chat_ui`.
class TicTacCallbacks {
  // ---------------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------------

  /// Auth succeeded, websocket up, heartbeat started. Fires once per
  /// [TicTacModule.connect] and again after every successful auto-reconnect.
  /// [topics] is the freshly-fetched subscription list.
  final void Function(List<Topic> topics)? onConnected;

  /// Connection lost — either heartbeat timeout or socket close.
  /// [reason] is a short human-readable description.
  ///
  /// Reconnect is automatic; this fires on every drop. If reconnection
  /// permanently fails (~7 min wall-clock cap), it fires with a final
  /// terminal reason and no further reconnect attempts are made.
  final void Function(String reason)? onDisconnected;

  // ---------------------------------------------------------------------------
  // Topic subscriptions
  // ---------------------------------------------------------------------------

  /// A new topic subscription appeared on the connected account (a friend
  /// added you, you accepted an invite, etc.). Note that topics you
  /// already had on [onConnected] do not refire here.
  final void Function(Topic topic)? onTopicAdded;

  /// A topic subscription went away (you left, you were unsubscribed,
  /// the topic was deleted upstream). [reason] is short — "left", "deleted".
  final void Function(String topicId, String reason)? onTopicRemoved;

  /// Topic metadata changed (display name, description, etc.).
  final void Function(Topic topic)? onTopicUpdated;

  // ---------------------------------------------------------------------------
  // Messages — global, across every joined topic
  // ---------------------------------------------------------------------------

  /// A message arrived (or was re-delivered on rejoin). Includes:
  /// - text messages
  /// - custom-typed messages (inspect `metadata['customType']` to dispatch)
  /// - server echoes of your own sends
  /// - cached history that comes in right after [TicTacModule.joinTopic]
  ///   (deferred / out-of-order with the future's resolution)
  ///
  /// The caller is responsible for deduplication — keyed by `message.id`
  /// covers re-deliveries; matching your own optimistic placeholders to
  /// echoes is your problem (TicTac doesn't know what UI you've drawn).
  final void Function(String topicId, types.Message message)? onMessageReceived;

  /// A message was deleted server-side. [messageId] is the seq string of
  /// the deleted message.
  final void Function(String topicId, String messageId)? onMessageDeleted;

  // ---------------------------------------------------------------------------
  // Per-topic state changes
  // ---------------------------------------------------------------------------

  /// A new member is in the topic. Fires for the existing roster on
  /// [TicTacModule.joinTopic] (one event per member) and for later joins.
  final void Function(String topicId, types.User member)? onMemberAdded;

  /// A member left or was kicked.
  final void Function(String topicId, String appUserId)? onMemberRemoved;

  /// A member came online or went offline within the topic context. The
  /// same change also fires at module scope (this carries [topicId] for
  /// per-topic UI; the wider [Topic]-list view should rely on the
  /// no-topic-id variant — see `onUserPresenceChanged`).
  final void Function(String topicId, String appUserId, bool isOnline)?
      onTopicPresenceChanged;

  /// Cross-topic presence: a contact in the user's me-topic subscriptions
  /// came online or went offline. Use for global "who's online" lists.
  final void Function(String appUserId, bool isOnline)? onUserPresenceChanged;

  /// A keystroke arrived from [appUserId] in [topicId]. Tinode does not
  /// emit "stopped typing" events; the caller decides how long to keep
  /// the indicator alive (`TicTacChat` uses a 3-second auto-clear timer).
  final void Function(String topicId, String appUserId)? onTypingStarted;

  const TicTacCallbacks({
    this.onConnected,
    this.onDisconnected,
    this.onTopicAdded,
    this.onTopicRemoved,
    this.onTopicUpdated,
    this.onMessageReceived,
    this.onMessageDeleted,
    this.onMemberAdded,
    this.onMemberRemoved,
    this.onTopicPresenceChanged,
    this.onUserPresenceChanged,
    this.onTypingStarted,
  });
}
