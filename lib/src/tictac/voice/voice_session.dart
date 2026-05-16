import 'package:livekit_client/livekit_client.dart' as lk;

import 'package:tictac/src/tictac/voice/voice_callbacks.dart';
import 'package:tictac/src/tictac/voice/voice_participant.dart';

/// Handle to an active voice session.
///
/// Created by [VoiceModule.joinVoice]. Owns the underlying LiveKit
/// [lk.Room]; translates LiveKit events into [VoiceParticipant]s with
/// app-user-ids resolved at the boundary, and fires the corresponding
/// callbacks on [VoiceCallbacks].
///
/// No participant roster is retained — each callback carries the
/// affected participant; the host accumulates whatever state it wants.
class VoiceSession {
  /// Canonical room name (server-derived). Surfaced for diagnostics.
  final String room;

  final lk.Room _room;
  final lk.EventsListener<lk.RoomEvent> _events;
  final Future<String?> Function(String tinodeUserId) _resolveAppUserId;
  final VoiceCallbacks _callbacks;

  bool _disposed = false;

  VoiceSession({
    required this.room,
    required lk.Room livekitRoom,
    required Future<String?> Function(String tinodeUserId) resolveAppUserId,
    required VoiceCallbacks callbacks,
  })  : _room = livekitRoom,
        _resolveAppUserId = resolveAppUserId,
        _callbacks = callbacks,
        _events = livekitRoom.createListener() {
    _wireEvents();
  }

  /// Mute or un-mute the local microphone.
  Future<void> mute(bool muted) async {
    await _room.localParticipant?.setMicrophoneEnabled(!muted);
  }

  /// Disconnect from the room and release resources. Idempotent.
  Future<void> leave() async {
    if (_disposed) return;
    _disposed = true;
    await _events.dispose();
    await _room.disconnect();
  }

  void _wireEvents() {
    _events
      ..on<lk.ParticipantConnectedEvent>((e) async {
        final p = await _toParticipant(e.participant);
        if (p != null) _callbacks.onParticipantJoined?.call(p);
      })
      ..on<lk.ParticipantDisconnectedEvent>((e) async {
        final p = await _toParticipant(e.participant);
        if (p != null) _callbacks.onParticipantLeft?.call(p);
      })
      ..on<lk.ActiveSpeakersChangedEvent>((e) async {
        for (final lkP in e.speakers) {
          final p = await _toParticipant(lkP);
          if (p != null) _callbacks.onSpeakingChanged?.call(p);
        }
      })
      ..on<lk.TrackMutedEvent>((e) async {
        final p = await _toParticipant(e.participant);
        if (p != null) _callbacks.onMuteChanged?.call(p);
      })
      ..on<lk.TrackUnmutedEvent>((e) async {
        final p = await _toParticipant(e.participant);
        if (p != null) _callbacks.onMuteChanged?.call(p);
      })
      ..on<lk.RoomDisconnectedEvent>((e) {
        _callbacks.onSessionEnded?.call(e.reason?.toString() ?? 'disconnected');
      });
  }

  Future<VoiceParticipant?> _toParticipant(lk.Participant lkP) async {
    final tinodeUid = lkP.identity;
    final appUserId = await _resolveAppUserId(tinodeUid);
    if (appUserId == null) return null;
    final isMuted = lkP.audioTrackPublications.isEmpty
        ? true
        : lkP.audioTrackPublications.first.muted;
    return VoiceParticipant(
      appUserId: appUserId,
      isSpeaking: lkP.isSpeaking,
      isMuted: isMuted,
      isLocal: lkP is lk.LocalParticipant,
    );
  }
}
