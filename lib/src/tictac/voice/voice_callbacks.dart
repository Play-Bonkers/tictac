import 'package:tictac/src/tictac/voice/voice_participant.dart';

/// Callbacks for events on an active [VoiceSession]. Pass an instance to
/// [TicTacModule.joinVoice].
///
/// Like [TicTacCallbacks], no state is retained inside the session — the
/// callbacks carry the relevant participant for each event and the host
/// accumulates whatever roster / mute-state / speaking-state it wants
/// to display.
class VoiceCallbacks {
  /// A remote participant joined the LiveKit room. Fires for each
  /// already-present participant on connect.
  final void Function(VoiceParticipant participant)? onParticipantJoined;

  /// A participant left the room.
  final void Function(VoiceParticipant participant)? onParticipantLeft;

  /// A participant's speaking state changed (audio level crossed
  /// LiveKit's threshold). Fires for both transitions: started / stopped
  /// speaking — inspect `participant.isSpeaking`.
  final void Function(VoiceParticipant participant)? onSpeakingChanged;

  /// A participant muted or unmuted their microphone — inspect
  /// `participant.isMuted`.
  final void Function(VoiceParticipant participant)? onMuteChanged;

  /// The LiveKit room disconnected. Reason is a short string.
  final void Function(String reason)? onSessionEnded;

  const VoiceCallbacks({
    this.onParticipantJoined,
    this.onParticipantLeft,
    this.onSpeakingChanged,
    this.onMuteChanged,
    this.onSessionEnded,
  });
}
