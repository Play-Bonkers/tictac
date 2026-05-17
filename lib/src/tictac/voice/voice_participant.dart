/// A participant in an active voice session.
///
/// Identified by app-level user-id (the tictac edge converts from the
/// LiveKit identity, which is the participant's Tinode user-id).
///
/// The per-event meaning is encoded in which [VoiceCallbacks] callback
/// fired (`onParticipantJoined` / `onParticipantLeft` /
/// `onSpeakingChanged` / `onMuteChanged`); the participant carries
/// only its current state.
class VoiceParticipant {
  final String appUserId;
  final bool isSpeaking;
  final bool isMuted;
  final bool isLocal;

  VoiceParticipant({
    required this.appUserId,
    required this.isSpeaking,
    required this.isMuted,
    required this.isLocal,
  });

  @override
  String toString() =>
      'VoiceParticipant($appUserId, speaking=$isSpeaking, muted=$isMuted, local=$isLocal)';
}
