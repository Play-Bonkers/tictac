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

  /// Highest seq the peer (anyone but us) has read, or 0 if unknown. UIs
  /// rebuilding on mount can use this to seed "seen" state synchronously
  /// instead of waiting for the next live `{info what=read}`.
  int peerReadSeq();
}
