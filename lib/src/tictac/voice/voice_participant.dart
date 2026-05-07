/// A participant in an active voice session.
///
/// Identified by app-level user-id (the tictac edge converts from the
/// LiveKit identity, which is the participant's Tinode user-id).
class VoiceParticipant {
  final String appUserId;
  final bool isSpeaking;
  final bool isMuted;
  final bool isLocal;
  final VoiceParticipantEvent event;

  VoiceParticipant({
    required this.appUserId,
    required this.isSpeaking,
    required this.isMuted,
    required this.isLocal,
    required this.event,
  });

  @override
  String toString() =>
      'VoiceParticipant($appUserId, speaking=$isSpeaking, muted=$isMuted, local=$isLocal, event=$event)';
}

enum VoiceParticipantEvent {
  joined,
  left,
  speakingChanged,
  muteChanged,
}
