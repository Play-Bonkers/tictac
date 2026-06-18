import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_test/flutter_test.dart';

import 'package:tictac/src/models/topic-subscription.dart';
import 'package:tictac/src/tictac/peer_read_state.dart';

/// Characterization tests for the p2p `Status.seen` semantics that
/// `TicTacChat` used to maintain inline. The class moves; the
/// behavior must not. Every case here was a manual smoke test before
/// BNK-593 — now they're a regression net for the per-member refactor
/// that will follow.

const _selfId = 'self';
const _peerId = 'peer';

types.TextMessage _msg({
  required String id,
  required String authorId,
  types.Status? status,
  String text = 'hi',
}) =>
    types.TextMessage(
      id: id,
      author: types.User(id: authorId),
      text: text,
      status: status,
    );

void main() {
  group('recordPeerRead', () {
    test('initial state is peerReadSeq = 0', () {
      const s = PeerReadState();
      expect(s.peerReadSeq, equals(0));
    });

    test('advances when seq is higher and reports changed', () {
      const s = PeerReadState();
      final result = s.recordPeerRead(5);
      expect(result.state.peerReadSeq, equals(5));
      expect(result.changed, isTrue);
    });

    test('returns same instance and changed=false for equal seq', () {
      const s = PeerReadState(peerReadSeq: 5);
      final result = s.recordPeerRead(5);
      expect(identical(result.state, s), isTrue,
          reason: 'equal seq is a no-op — must not allocate a new state');
      expect(result.changed, isFalse);
    });

    test('returns same instance and changed=false for lower seq', () {
      // Peer-read markers never regress — Tinode delivers them in
      // monotonic order and an out-of-order replay should be ignored.
      const s = PeerReadState(peerReadSeq: 5);
      final result = s.recordPeerRead(3);
      expect(identical(result.state, s), isTrue);
      expect(result.changed, isFalse);
    });

    test('chained advances each advance peerReadSeq', () {
      var s = const PeerReadState();
      s = s.recordPeerRead(1).state;
      s = s.recordPeerRead(2).state;
      s = s.recordPeerRead(7).state;
      expect(s.peerReadSeq, equals(7));
    });
  });

  group('applyToMessage', () {
    test('is a no-op when peerReadSeq is zero', () {
      const s = PeerReadState();
      final msg =
          _msg(id: '1', authorId: _selfId, status: types.Status.sent);
      expect(identical(s.applyToMessage(msg, _selfId), msg), isTrue);
    });

    test('passes through non-self author messages', () {
      const s = PeerReadState(peerReadSeq: 10);
      final msg =
          _msg(id: '1', authorId: _peerId, status: types.Status.sent);
      expect(identical(s.applyToMessage(msg, _selfId), msg), isTrue);
    });

    test('passes through already-seen messages', () {
      const s = PeerReadState(peerReadSeq: 10);
      final msg =
          _msg(id: '1', authorId: _selfId, status: types.Status.seen);
      expect(identical(s.applyToMessage(msg, _selfId), msg), isTrue);
    });

    test('passes through non-numeric ids (optimistic uuid placeholders)',
        () {
      // Optimistic-send placeholders carry uuid ids until the server
      // echo replaces them; they must NOT be stamped seen by an
      // unrelated peer-read marker.
      const s = PeerReadState(peerReadSeq: 10);
      final msg = _msg(
        id: '550e8400-e29b-41d4-a716-446655440000',
        authorId: _selfId,
        status: types.Status.sending,
      );
      expect(identical(s.applyToMessage(msg, _selfId), msg), isTrue);
    });

    test('passes through messages with seq above peerReadSeq', () {
      const s = PeerReadState(peerReadSeq: 5);
      final msg =
          _msg(id: '10', authorId: _selfId, status: types.Status.sent);
      expect(identical(s.applyToMessage(msg, _selfId), msg), isTrue);
    });

    test('stamps Status.seen at the exact boundary (seq == peerReadSeq)',
        () {
      const s = PeerReadState(peerReadSeq: 5);
      final msg =
          _msg(id: '5', authorId: _selfId, status: types.Status.sent);
      final out = s.applyToMessage(msg, _selfId) as types.TextMessage;
      expect(out.status, equals(types.Status.seen));
    });

    test('stamps Status.seen for seq below peerReadSeq', () {
      const s = PeerReadState(peerReadSeq: 10);
      final msg =
          _msg(id: '3', authorId: _selfId, status: types.Status.sent);
      final out = s.applyToMessage(msg, _selfId) as types.TextMessage;
      expect(out.status, equals(types.Status.seen));
    });

    test('stamps from Status.sending too — late echo race', () {
      // The optimistic placeholder swap is supposed to land before the
      // peer-read marker, but a slow replace shouldn't strand an own
      // message at Status.sending if it's covered.
      const s = PeerReadState(peerReadSeq: 5);
      final msg =
          _msg(id: '3', authorId: _selfId, status: types.Status.sending);
      final out = s.applyToMessage(msg, _selfId) as types.TextMessage;
      expect(out.status, equals(types.Status.seen));
    });

    test('preserves other fields when copying', () {
      const s = PeerReadState(peerReadSeq: 10);
      final msg = _msg(
        id: '3',
        authorId: _selfId,
        status: types.Status.sent,
        text: 'hello world',
      );
      final out = s.applyToMessage(msg, _selfId) as types.TextMessage;
      expect(out.id, equals('3'));
      expect(out.text, equals('hello world'));
      expect(out.author.id, equals(_selfId));
      expect(out.status, equals(types.Status.seen));
    });

    test('re-applying to an already-seen result is a no-op', () {
      // Idempotency matters because TicTacChat re-applies on every
      // insert/replace.
      const s = PeerReadState(peerReadSeq: 10);
      final msg =
          _msg(id: '3', authorId: _selfId, status: types.Status.sent);
      final first = s.applyToMessage(msg, _selfId);
      final second = s.applyToMessage(first, _selfId);
      expect(identical(first, second), isTrue);
    });
  });

  group('TicTacChat in-widget race semantics', () {
    test('peer-read arriving before its own data frame: state advances; '
        'the late-arriving frame gets stamped on insert', () {
      // Scenario from the BNK-562 bug class: peer's read marker for
      // seq=7 arrives before our own data frame for seq=7 lands in the
      // list. The widget calls recordPeerRead first; later, when the
      // data frame finally arrives, _applyPeerRead must stamp it.
      var s = const PeerReadState();
      s = s.recordPeerRead(7).state;
      final lateFrame =
          _msg(id: '7', authorId: _selfId, status: types.Status.sent);
      final out = s.applyToMessage(lateFrame, _selfId) as types.TextMessage;
      expect(out.status, equals(types.Status.seen));
    });

    test('replay of older messages after the read marker advanced keeps '
        'Status.seen — does not regress to sent', () {
      // Scenario: tictac re-delivers cached messages on reconnect or
      // joinTopic-cache-replay. Each replay calls _applyPeerRead. The
      // peer-read marker (stored in state) covers them — they must
      // come out as seen, not sent.
      const s = PeerReadState(peerReadSeq: 10);
      final replays = [1, 2, 3, 4, 5].map((seq) => _msg(
            id: '$seq',
            authorId: _selfId,
            status: types.Status.sent,
          ));
      for (final m in replays) {
        final out = s.applyToMessage(m, _selfId) as types.TextMessage;
        expect(out.status, equals(types.Status.seen),
            reason: 'replay of seq ${m.id} after peer-read=10 must be seen');
      }
    });

    test('mixed list scan: only own messages at-or-below get stamped', () {
      // _handleRead walks _messages and stamps applicable items. Verify
      // a representative list resolves correctly.
      const s = PeerReadState(peerReadSeq: 5);
      final list = <types.Message>[
        _msg(id: '1', authorId: _selfId, status: types.Status.sent),
        _msg(id: '2', authorId: _peerId, status: types.Status.sent),
        _msg(id: '3', authorId: _selfId, status: types.Status.seen),
        _msg(id: '5', authorId: _selfId, status: types.Status.sent),
        _msg(id: '6', authorId: _selfId, status: types.Status.sent),
        _msg(
          id: 'uuid-placeholder',
          authorId: _selfId,
          status: types.Status.sending,
        ),
      ];
      final stamped =
          list.map((m) => s.applyToMessage(m, _selfId)).toList();

      expect((stamped[0] as types.TextMessage).status,
          equals(types.Status.seen),
          reason: 'id=1, own, <= 5 → seen');
      expect(identical(stamped[1], list[1]), isTrue,
          reason: 'id=2, peer author → unchanged');
      expect(identical(stamped[2], list[2]), isTrue,
          reason: 'id=3, own, already seen → identity preserved');
      expect((stamped[3] as types.TextMessage).status,
          equals(types.Status.seen),
          reason: 'id=5 at boundary → seen');
      expect(identical(stamped[4], list[4]), isTrue,
          reason: 'id=6 > 5 → unchanged');
      expect(identical(stamped[5], list[5]), isTrue,
          reason: 'non-numeric uuid → unchanged');
    });
  });

  group('maxPeerRead', () {
    TopicSubscription _sub(String user, int? read) =>
        TopicSubscription(user: user, read: read);

    test('empty subscribers → 0', () {
      expect(PeerReadState.maxPeerRead(const [], _selfId), equals(0));
    });

    test('only self subscriber → 0', () {
      expect(
        PeerReadState.maxPeerRead([_sub(_selfId, 10)], _selfId),
        equals(0),
        reason: 'self reads do not count toward peer-read aggregate',
      );
    });

    test('single peer with positive read → that seq', () {
      expect(
        PeerReadState.maxPeerRead([_sub(_peerId, 7)], _selfId),
        equals(7),
      );
    });

    test('multiple peers → max across them', () {
      expect(
        PeerReadState.maxPeerRead(
          [_sub(_peerId, 3), _sub('peer2', 9), _sub('peer3', 5)],
          _selfId,
        ),
        equals(9),
      );
    });

    test('mixed self + peers → max excludes self', () {
      expect(
        PeerReadState.maxPeerRead(
          [_sub(_selfId, 100), _sub(_peerId, 5)],
          _selfId,
        ),
        equals(5),
      );
    });

    test('null read counts as no signal', () {
      expect(
        PeerReadState.maxPeerRead(
          [_sub(_peerId, null), _sub('peer2', 4)],
          _selfId,
        ),
        equals(4),
      );
    });

    test('zero read counts as no signal', () {
      expect(
        PeerReadState.maxPeerRead(
          [_sub(_peerId, 0), _sub('peer2', 4)],
          _selfId,
        ),
        equals(4),
      );
    });

    test('negative read counts as no signal', () {
      expect(
        PeerReadState.maxPeerRead([_sub(_peerId, -1)], _selfId),
        equals(0),
      );
    });

    test('null selfId → no filter, every subscriber counts', () {
      // Matches the pre-extraction behaviour where the early-init path
      // (Tinode not yet authenticated) couldn't tell ourselves from a
      // peer. Documenting the degenerate behaviour so a future
      // refactor doesn't silently change it.
      expect(
        PeerReadState.maxPeerRead(
          [_sub(_selfId, 100), _sub(_peerId, 5)],
          null,
        ),
        equals(100),
      );
    });

    test('all subscribers null read → 0', () {
      expect(
        PeerReadState.maxPeerRead(
          [_sub(_peerId, null), _sub('peer2', null)],
          _selfId,
        ),
        equals(0),
      );
    });
  });
}
