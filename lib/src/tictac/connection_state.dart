/// Connection state for TicTac chat.
enum TicTacConnectionState {
  /// No connection, not trying.
  disconnected,

  /// Actively establishing connection.
  connecting,

  /// WebSocket open, authenticated, subscribed to 'me'.
  connected,

  /// Connection lost, attempting to restore.
  reconnecting,

  /// Gave up after max reconnect duration.
  failed,
}
