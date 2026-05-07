import 'dart:convert';
import 'dart:io';

import 'package:livekit_client/livekit_client.dart' as lk;

import 'package:tictac/src/tictac/identity/identity_resolver.dart';
import 'package:tictac/src/tictac/tictac_config.dart';
import 'package:tictac/src/tictac/voice/voice_session.dart';

/// Voice support for tictac, backed by LiveKit.
///
/// The module talks to the `tinode-tokenizer` Lambda (via TAGS) to mint a
/// short-lived LiveKit JWT scoped to a canonical room derived from a Tinode
/// topic the caller is subscribed to. After receiving the JWT it connects
/// the LiveKit Dart SDK to the room and returns a [VoiceSession].
///
/// Public API takes app-user-ids and topic-ids. LiveKit identities (Tinode
/// user-ids) are resolved at the edge via the [IdentityResolver] supplied
/// by [TicTacModule], consistent with the rest of tictac.
class VoiceModule {
  final TicTacConfig _config;
  final IdentityResolver _identityResolver;
  final HttpClient _httpClient = HttpClient();

  VoiceModule({
    required TicTacConfig config,
    required IdentityResolver identityResolver,
  })  : _config = config,
        _identityResolver = identityResolver {
    _httpClient.connectionTimeout = const Duration(seconds: 5);
  }

  /// Mint a token for [topicId] and connect to the corresponding LiveKit
  /// room. The caller must already be subscribed to [topicId] in Tinode —
  /// the server verifies this and rejects with 403 otherwise.
  Future<VoiceSession> joinVoice(String topicId) async {
    final tagsBaseUrl = _config.tagsBaseUrl;
    if (tagsBaseUrl == null || tagsBaseUrl.isEmpty) {
      throw StateError(
        'TicTacConfig.tagsBaseUrl is required for voice (token-mint endpoint)',
      );
    }
    final getToken = _config.getFirebaseIdToken;
    if (getToken == null) {
      throw StateError(
        'TicTacConfig.getFirebaseIdToken is required for voice — supply a callback that returns a Firebase ID token',
      );
    }
    final firebaseIdToken = await getToken();
    if (firebaseIdToken == null || firebaseIdToken.isEmpty) {
      throw StateError(
        'getFirebaseIdToken returned null/empty; cannot mint LiveKit token',
      );
    }

    final mintResponse = await _mintToken(
      tagsBaseUrl: tagsBaseUrl,
      firebaseIdToken: firebaseIdToken,
      topicId: topicId,
    );

    final livekitUrl = mintResponse['livekit_url'] as String;
    final accessToken = mintResponse['token'] as String;
    final room = mintResponse['room'] as String;

    final lkRoom = lk.Room(
      roomOptions: const lk.RoomOptions(
        adaptiveStream: true,
        dynacast: true,
      ),
    );
    await lkRoom.connect(livekitUrl, accessToken);
    // Publish mic immediately so the session is two-way by default. Callers
    // can flip this off via VoiceSession.mute(true).
    await lkRoom.localParticipant?.setMicrophoneEnabled(true);

    return VoiceSession(
      room: room,
      livekitRoom: lkRoom,
      identityResolver: _identityResolver,
    );
  }

  Future<Map<String, dynamic>> _mintToken({
    required String tagsBaseUrl,
    required String firebaseIdToken,
    required String topicId,
  }) async {
    final uri = Uri.parse('$tagsBaseUrl/voice/token');
    final request = await _httpClient.postUrl(uri);
    request.headers.set('content-type', 'application/json');
    request.headers.set('authorization', 'Bearer $firebaseIdToken');
    request.headers.set('x-app-id', _config.appId);
    request.headers.set('x-app-key', _config.appKey);
    request.write(jsonEncode({
      'topic_id': topicId,
      'app_user_id': _config.appUserId,
    }));

    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      throw VoiceTokenException(
        statusCode: response.statusCode,
        body: body,
      );
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }
}

/// Thrown when the token-mint endpoint rejects a [VoiceModule.joinVoice]
/// call. [statusCode] surfaces the upstream HTTP status; common cases are
/// 401 (Firebase token invalid/expired), 403 (caller not subscribed to the
/// topic, or app_user_id binding mismatch), and 5xx (upstream outage).
class VoiceTokenException implements Exception {
  final int statusCode;
  final String body;

  VoiceTokenException({required this.statusCode, required this.body});

  @override
  String toString() => 'VoiceTokenException($statusCode): $body';
}
