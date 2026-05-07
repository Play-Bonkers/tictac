import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;

import 'package:tictac/src/tictac/identity/identity_resolver.dart';
import 'package:tictac/src/tictac/voice/voice_participant.dart';

/// Handle to an active voice session.
///
/// Created by [VoiceModule.joinVoice]. Owns the underlying LiveKit [lk.Room]
/// and translates LiveKit events into tictac-shaped [VoiceParticipant]
/// updates with app-user-ids resolved at the boundary.
class VoiceSession {
  /// The canonical room name the session connected to (server-derived,
  /// returned from the token-mint endpoint). Surfaced for diagnostics —
  /// callers should not need to interpret it.
  final String room;

  final lk.Room _room;
  final IdentityResolver _identityResolver;
  final lk.EventsListener<lk.RoomEvent> _events;
  final StreamController<VoiceParticipant> _participantController =
      StreamController<VoiceParticipant>.broadcast();

  bool _disposed = false;

  VoiceSession({
    required this.room,
    required lk.Room livekitRoom,
    required IdentityResolver identityResolver,
  })  : _room = livekitRoom,
        _identityResolver = identityResolver,
        _events = livekitRoom.createListener() {
    _wireEvents();
  }

  /// Stream of participant events. Emits joined/left and speaking/mute
  /// changes for every participant in the room (including local).
  Stream<VoiceParticipant> get participantUpdates =>
      _participantController.stream;

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
    await _participantController.close();
  }

  void _wireEvents() {
    _events
      ..on<lk.ParticipantConnectedEvent>((e) async {
        final p = await _toVoiceParticipant(
          e.participant,
          VoiceParticipantEvent.joined,
        );
        if (p != null) _participantController.add(p);
      })
      ..on<lk.ParticipantDisconnectedEvent>((e) async {
        final p = await _toVoiceParticipant(
          e.participant,
          VoiceParticipantEvent.left,
        );
        if (p != null) _participantController.add(p);
      })
      ..on<lk.ActiveSpeakersChangedEvent>((e) async {
        for (final lkP in e.speakers) {
          final p = await _toVoiceParticipant(
            lkP,
            VoiceParticipantEvent.speakingChanged,
          );
          if (p != null) _participantController.add(p);
        }
      })
      ..on<lk.TrackMutedEvent>((e) async {
        final p = await _toVoiceParticipant(
          e.participant,
          VoiceParticipantEvent.muteChanged,
        );
        if (p != null) _participantController.add(p);
      })
      ..on<lk.TrackUnmutedEvent>((e) async {
        final p = await _toVoiceParticipant(
          e.participant,
          VoiceParticipantEvent.muteChanged,
        );
        if (p != null) _participantController.add(p);
      });
  }

  Future<VoiceParticipant?> _toVoiceParticipant(
    lk.Participant lkP,
    VoiceParticipantEvent event,
  ) async {
    final tinodeUid = lkP.identity;
    final appUserId = await _identityResolver.reverseLookup(tinodeUid);
    if (appUserId == null) {
      // Without an app-user-id we have nothing useful to surface to the
      // host app. Drop the event rather than leaking the internal id.
      return null;
    }
    final isMuted = lkP.audioTrackPublications.isEmpty
        ? true
        : lkP.audioTrackPublications.first.muted;
    return VoiceParticipant(
      appUserId: appUserId,
      isSpeaking: lkP.isSpeaking,
      isMuted: isMuted,
      isLocal: lkP is lk.LocalParticipant,
      event: event,
    );
  }
}
