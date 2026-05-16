/// The triple a [VoiceModule] needs to connect to a LiveKit room.
///
/// Returned by [TicTacConfig.mintVoiceToken] — the host is responsible
/// for the HTTP roundtrip to whatever token-mint endpoint it runs (TAGS,
/// a custom Lambda, etc.) and packages the result in this shape.
class VoiceToken {
  /// Short-lived LiveKit access token (JWT) granting `join` + publish
  /// rights on the room.
  final String accessToken;

  /// LiveKit server URL (e.g. `wss://livekit.example.com`).
  final String livekitUrl;

  /// Canonical room name the token is scoped to. tictac uses this only
  /// for diagnostic logging — the SDK pulls the room from the token.
  final String room;

  const VoiceToken({
    required this.accessToken,
    required this.livekitUrl,
    required this.room,
  });
}

/// Convenience exception for hosts that want to surface upstream HTTP
/// status from their `mintVoiceToken` implementation. Optional — hosts
/// can throw anything; tictac will surface whatever bubbles up.
class VoiceTokenException implements Exception {
  final int statusCode;
  final String body;

  VoiceTokenException({required this.statusCode, required this.body});

  @override
  String toString() => 'VoiceTokenException($statusCode): $body';
}
