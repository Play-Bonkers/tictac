/// Methods-only handle returned by [TicTacModule.joinTopic].
///
/// Holds no message / member / presence state — those flow as callbacks
/// on [TicTacCallbacks]. The handle exists only to expose
/// per-topic actions (send, mark read, set typing, leave).
///
/// Lifetime is tied to the join: calling [leave] (or the module being
/// disposed) makes further calls on this handle a no-op.
abstract class TopicHandle {
  /// The Tinode topic id this handle wraps.
  String get topicId;

  /// Send a plain text message.
  ///
  /// Returns when Tinode has accepted the publish. The corresponding
  /// `onMessageReceived` callback fires separately once the server echoes
  /// the message back — that's when it gets its real seq id. The caller
  /// is responsible for any optimistic UI placeholder and for matching
  /// the placeholder against the echo.
  Future<void> sendText(String text);

  /// Send a custom-typed message. `customType` is an app-level string that
  /// callers `customMessageBuilder` will switch on. `payload` is arbitrary
  /// JSON; `fallbackText` is what clients that don't understand the type
  /// will render instead.
  Future<void> sendCustom(
    String customType,
    Map<String, dynamic> payload, {
    String? fallbackText,
  });

  /// Mark a message as read by its seq id. Debounced by the underlying
  /// SDK — safe to call repeatedly with the same id.
  Future<void> markRead(String messageId);

  /// Send a "key press" notification. Tinode broadcasts this to peers,
  /// who'll see [TicTacCallbacks.onTypingStarted] fire for this user.
  /// Pass `false` to no-op (kept for API symmetry with the old API; the
  /// protocol has no "stop typing" event).
  Future<void> setTyping(bool isTyping);

  /// Delete a message by its seq id. The corresponding
  /// `onMessageDeleted` callback fires once the server confirms.
  Future<void> deleteMessage(String messageId);

  /// Leave the topic. After this returns, further calls on this handle
  /// are no-ops, no callbacks fire for this topic, and the handle should
  /// be discarded.
  Future<void> leave();

  /// Highest seq any peer has read, or 0 if unknown. UIs rebuilding on
  /// mount can use this to seed p2p "seen" state synchronously without
  /// waiting for the next live `{info what=read}`. For groups where
  /// the host needs per-member visibility (BNK-593's "all members read
  /// = blue tick"), use [peerReadSeqs] instead — this method only
  /// surfaces the max and would over-report coverage.
  int peerReadSeq();

  /// Per-member view of [peerReadSeq]. Returns each non-self
  /// subscriber's read marker keyed by appUserId. Empty map if no peer
  /// has read anything (e.g. cold mount before the first
  /// `{info what=read}` lands). Hosts implementing the group "all
  /// members read" semantic feed this directly into
  /// `PeerReadState.peerReadSeqByUser`.
  ///
  /// Tinode user ids are resolved to appUserIds via
  /// [TicTacConfig.resolveAppUserId]; unresolved subscribers are
  /// dropped silently (matches every other resolve site in this SDK).
  Future<Map<String, int>> peerReadSeqs();

  /// Invite an app user to this topic with default member access. Resolves
  /// the appUserId to a Tinode user id via
  /// [TicTacConfig.resolveTinodeUserIds]; throws [StateError] if no
  /// resolver is configured or [ArgumentError] if the id can't be
  /// resolved. The corresponding [TicTacCallbacks.onMemberAdded] fires
  /// once the server confirms.
  ///
  /// Default access mode is `JRWP` (Join, Read, Write, Presence) — plain
  /// member. To promote to admin or change roles later, use a future
  /// `updateMode` method (not yet exposed).
  Future<void> invite(String appUserId);

  /// Eject an app user from this topic. Resolves the appUserId to a
  /// Tinode user id; throws like [invite]. Implemented as
  /// `invite(appUserId, mode: 'N')` since the underlying Tinode SDK
  /// doesn't expose a dedicated eject — setting access mode to None is
  /// the eject pattern. [TicTacCallbacks.onMemberRemoved] fires once the
  /// server confirms.
  Future<void> eject(String appUserId);

  /// Update the topic's display name (Tinode `desc.public.fn`). Visible
  /// to all members. [TicTacCallbacks.onTopicUpdated] fires for every
  /// member once the server confirms.
  Future<void> setName(String name);

  /// Update the topic's photo URL (Tinode `desc.public.photo`). Tinode
  /// treats `public` as opaque JSON — this method only stores the URL,
  /// not bytes. Upload pipeline (pick / resize / upload) is the caller's
  /// responsibility.
  Future<void> setPhoto(String url);
}
