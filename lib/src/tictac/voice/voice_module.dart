import 'package:livekit_client/livekit_client.dart' as lk;

import 'package:tictac/src/tictac/tictac_config.dart';
import 'package:tictac/src/tictac/voice/voice_callbacks.dart';
import 'package:tictac/src/tictac/voice/voice_session.dart';
import 'package:tictac/src/tictac/voice/voice_token.dart';

/// Voice support for tictac, backed by LiveKit.
///
/// tictac is intentionally agnostic about how the LiveKit token is
/// minted — that's the host's [TicTacConfig.mintVoiceToken] callback.
/// This module just consumes the [VoiceToken] the host returns and
/// connects the LiveKit Dart SDK.
class VoiceModule {
  final TicTacConfig _config;

  VoiceModule({required TicTacConfig config}) : _config = config;

  /// Mint a token for [topicId] (via the host's `mintVoiceToken`
  /// callback) and connect to the corresponding LiveKit room. All
  /// voice events fire through [callbacks].
  Future<VoiceSession> joinVoice(
    String topicId,
    VoiceCallbacks callbacks,
  ) async {
    final mint = _config.mintVoiceToken;
    if (mint == null) {
      throw StateError(
        'TicTacConfig.mintVoiceToken is required to start a voice call — '
        'supply a callback that returns a VoiceToken for the given topicId.',
      );
    }
    final VoiceToken token = await mint(topicId);

    final lkRoom = lk.Room(
      roomOptions: const lk.RoomOptions(
        adaptiveStream: true,
        dynacast: true,
      ),
    );
    await lkRoom.connect(token.livekitUrl, token.accessToken);
    // Publish mic immediately so the session is two-way by default.
    // Callers can flip this off via VoiceSession.mute(true).
    await lkRoom.localParticipant?.setMicrophoneEnabled(true);

    return VoiceSession(
      room: token.room,
      livekitRoom: lkRoom,
      resolveAppUserId: _config.resolveAppUserId,
      callbacks: callbacks,
    );
  }
}
