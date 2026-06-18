import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_test/flutter_test.dart';

import 'package:tictac/src/models/topic-subscription.dart';
import 'package:tictac/src/tictac/peer_read_state.dart';

/// BNK-593: per-member read-receipt characterization + group tests.
///
/// The p2p contract from the prep PR is preserved as-is (now expressed
/// through the per-user map + `requireAllOf: null` mode). Group
/// semantics (`requireAllOf: <member set>` → all-must-read) are new
/// for this PR and have dedicated coverage below.

const _selfId = 'self';
const _peerId = 'peer';
const _peerId2 = 'peer2';
const _peerId3 = 'peer3';

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
  group('recordPeerRead — per-user', () {
    test('initial state has empty map and maxSeq=0', () {
      const s = PeerReadState();
      expect(s.peerReadSeqByUser, isEmpty);
      expect(s.maxSeq, equals(0));
    });

    test('advances a new user from absent to seq', () {
      const s = PeerReadState();
      final r = s.recordPeerRead(_peerId, 5);
      expect(r.state.peerReadSeqByUser[_peerId], equals(5));
      expect(r.changed, isTrue);
    });

    test('advances an existing user when seq is higher', () {
      const s =
          PeerReadState(peerReadSeqByUser: {_peerId: 3});
      final r = s.recordPeerRead(_peerId, 10);
      expect(r.state.peerReadSeqByUser[_peerId], equals(10));
      expect(r.changed, isTrue);
    });

    test('equal seq is a no-op and preserves identity', () {
      const s =
          PeerReadState(peerReadSeqByUser: {_peerId: 5});
      final r = s.recordPeerRead(_peerId, 5);
      expect(identical(r.state, s), isTrue);
      expect(r.changed, isFalse);
    });

    test('lower seq is a no-op and preserves identity', () {
      const s =
          PeerReadState(peerReadSeqByUser: {_peerId: 5});
      final r = s.recordPeerRead(_peerId, 3);
      expect(identical(r.state, s), isTrue);
      expect(r.changed, isFalse);
    });

    test('per-user advances are independent', () {
      var s = const PeerReadState();
      s = s.recordPeerRead(_peerId, 5).state;
      s = s.recordPeerRead(_peerId2, 10).state;
      s = s.recordPeerRead(_peerId, 7).state;
      expect(s.peerReadSeqByUser[_peerId], equals(7));
      expect(s.peerReadSeqByUser[_peerId2], equals(10));
      expect(s.maxSeq, equals(10));
    });

    test('advance returns a new map (immutability)', () {
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 5});
      final r = s.recordPeerRead(_peerId2, 7);
      expect(identical(r.state.peerReadSeqByUser, s.peerReadSeqByUser),
          isFalse,
          reason: 'must allocate a fresh map, not mutate the existing one');
    });
  });

  group('applyToMessage — p2p (requireAllOf: null)', () {
    test('no-op when map is empty (nothing covered)', () {
      const s = PeerReadState();
      final msg =
          _msg(id: '1', authorId: _selfId, status: types.Status.sent);
      expect(identical(s.applyToMessage(msg, _selfId), msg), isTrue);
    });

    test('passes through non-self author messages', () {
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 10});
      final msg =
          _msg(id: '1', authorId: _peerId, status: types.Status.sent);
      expect(identical(s.applyToMessage(msg, _selfId), msg), isTrue);
    });

    test('passes through already-seen messages', () {
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 10});
      final msg =
          _msg(id: '1', authorId: _selfId, status: types.Status.seen);
      expect(identical(s.applyToMessage(msg, _selfId), msg), isTrue);
    });

    test('passes through non-numeric ids (optimistic uuid placeholders)',
        () {
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 10});
      final msg = _msg(
        id: '550e8400-e29b-41d4-a716-446655440000',
        authorId: _selfId,
        status: types.Status.sending,
      );
      expect(identical(s.applyToMessage(msg, _selfId), msg), isTrue);
    });

    test('passes through messages with seq above any peer marker', () {
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 5});
      final msg =
          _msg(id: '10', authorId: _selfId, status: types.Status.sent);
      expect(identical(s.applyToMessage(msg, _selfId), msg), isTrue);
    });

    test('stamps Status.seen at the exact boundary (seq == marker)', () {
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 5});
      final msg =
          _msg(id: '5', authorId: _selfId, status: types.Status.sent);
      final out = s.applyToMessage(msg, _selfId) as types.TextMessage;
      expect(out.status, equals(types.Status.seen));
    });

    test('any one peer covers — multiple peers, only one needs to reach',
        () {
      // p2p semantic for the multi-peer case (e.g. a chat upgraded
      // from p2p to group should still let any one peer's read cover
      // until the caller switches modes).
      const s = PeerReadState(
        peerReadSeqByUser: {_peerId: 3, _peerId2: 10, _peerId3: 1},
      );
      final msg =
          _msg(id: '7', authorId: _selfId, status: types.Status.sent);
      final out = s.applyToMessage(msg, _selfId) as types.TextMessage;
      expect(out.status, equals(types.Status.seen),
          reason: 'peer2 covers — that is enough for p2p mode');
    });

    test('stamps from Status.sending too — late echo race', () {
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 5});
      final msg =
          _msg(id: '3', authorId: _selfId, status: types.Status.sending);
      final out = s.applyToMessage(msg, _selfId) as types.TextMessage;
      expect(out.status, equals(types.Status.seen));
    });

    test('preserves other fields when copying', () {
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 10});
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
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 10});
      final msg =
          _msg(id: '3', authorId: _selfId, status: types.Status.sent);
      final first = s.applyToMessage(msg, _selfId);
      final second = s.applyToMessage(first, _selfId);
      expect(identical(first, second), isTrue);
    });
  });

  group('applyToMessage — group (requireAllOf: <set>)', () {
    test('seen when every required peer has covered', () {
      const s = PeerReadState(
        peerReadSeqByUser: {_peerId: 7, _peerId2: 10},
      );
      final msg =
          _msg(id: '5', authorId: _selfId, status: types.Status.sent);
      final out = s.applyToMessage(
        msg,
        _selfId,
        requireAllOf: {_peerId, _peerId2},
      ) as types.TextMessage;
      expect(out.status, equals(types.Status.seen));
    });

    test('not seen when any single peer hasn\'t reached the seq', () {
      const s = PeerReadState(
        peerReadSeqByUser: {_peerId: 7, _peerId2: 3},
      );
      final msg =
          _msg(id: '5', authorId: _selfId, status: types.Status.sent);
      expect(
        identical(
          s.applyToMessage(
            msg,
            _selfId,
            requireAllOf: {_peerId, _peerId2},
          ),
          msg,
        ),
        isTrue,
        reason: 'peer2 is at 3 — below msg seq 5 — must not stamp',
      );
    });

    test('not seen when a required peer is missing from the map', () {
      // A late joiner who hasn't sent a read marker yet must block the
      // blue tick. Conservative semantic — matches user expectation
      // "everyone who is currently in this chat".
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 10});
      final msg =
          _msg(id: '5', authorId: _selfId, status: types.Status.sent);
      expect(
        identical(
          s.applyToMessage(
            msg,
            _selfId,
            requireAllOf: {_peerId, _peerId2},
          ),
          msg,
        ),
        isTrue,
        reason: 'peer2 has no entry → counts as unread → must not stamp',
      );
    });

    test('empty required set never marks seen', () {
      // An empty group (no non-self members) shouldn't get the tick.
      // Edge case — would surface if a member was ejected mid-read.
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 10});
      final msg =
          _msg(id: '3', authorId: _selfId, status: types.Status.sent);
      expect(
        identical(
          s.applyToMessage(msg, _selfId, requireAllOf: const {}),
          msg,
        ),
        isTrue,
      );
    });

    test('extra peers in the map (no longer required) are ignored', () {
      // Member ejected since: peer3 was a member when they read seq 10,
      // but the caller no longer lists them in requireAllOf. Their
      // read shouldn't be required for coverage.
      const s = PeerReadState(
        peerReadSeqByUser: {_peerId: 7, _peerId2: 7, _peerId3: 1},
      );
      final msg =
          _msg(id: '5', authorId: _selfId, status: types.Status.sent);
      final out = s.applyToMessage(
        msg,
        _selfId,
        requireAllOf: {_peerId, _peerId2},
      ) as types.TextMessage;
      expect(out.status, equals(types.Status.seen),
          reason: 'peer3 is ejected — not required — must not block');
    });

    test('boundary case: all required peers exactly at msg seq', () {
      const s = PeerReadState(
        peerReadSeqByUser: {_peerId: 5, _peerId2: 5, _peerId3: 5},
      );
      final msg =
          _msg(id: '5', authorId: _selfId, status: types.Status.sent);
      final out = s.applyToMessage(
        msg,
        _selfId,
        requireAllOf: {_peerId, _peerId2, _peerId3},
      ) as types.TextMessage;
      expect(out.status, equals(types.Status.seen));
    });

    test('progressive coverage: missing → partial → full', () {
      // The bug class we care about: as each peer reads, the tick
      // should NOT flip until the last one has read.
      const msgSeq = 5;
      final requireAllOf = {_peerId, _peerId2, _peerId3};
      final msg = _msg(
        id: '$msgSeq',
        authorId: _selfId,
        status: types.Status.sent,
      );

      var s = const PeerReadState();
      // No one has read.
      expect(
          identical(
            s.applyToMessage(msg, _selfId, requireAllOf: requireAllOf),
            msg,
          ),
          isTrue);

      // peer1 reads.
      s = s.recordPeerRead(_peerId, msgSeq).state;
      expect(
          identical(
            s.applyToMessage(msg, _selfId, requireAllOf: requireAllOf),
            msg,
          ),
          isTrue,
          reason: 'still missing peer2, peer3 — must not flip');

      // peer2 reads.
      s = s.recordPeerRead(_peerId2, msgSeq).state;
      expect(
          identical(
            s.applyToMessage(msg, _selfId, requireAllOf: requireAllOf),
            msg,
          ),
          isTrue,
          reason: 'still missing peer3 — must not flip');

      // peer3 reads — NOW it flips.
      s = s.recordPeerRead(_peerId3, msgSeq).state;
      final out = s.applyToMessage(
        msg,
        _selfId,
        requireAllOf: requireAllOf,
      ) as types.TextMessage;
      expect(out.status, equals(types.Status.seen),
          reason: 'all required peers covered — must flip now');
    });
  });

  group('isCovered — public helper for host walks', () {
    test('p2p mode: any peer covers', () {
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 10});
      expect(s.isCovered(5), isTrue);
      expect(s.isCovered(10), isTrue);
      expect(s.isCovered(11), isFalse);
    });

    test('p2p mode with empty map: never covered', () {
      const s = PeerReadState();
      expect(s.isCovered(1), isFalse);
    });

    test('group mode: requires all-listed', () {
      const s = PeerReadState(
        peerReadSeqByUser: {_peerId: 10, _peerId2: 5},
      );
      expect(s.isCovered(5, requireAllOf: {_peerId, _peerId2}), isTrue);
      expect(s.isCovered(10, requireAllOf: {_peerId, _peerId2}), isFalse,
          reason: 'peer2 only at 5');
    });
  });

  group('TicTacChat in-widget race semantics', () {
    test('peer-read arriving before its own data frame: state advances; '
        'the late-arriving frame gets stamped on insert', () {
      var s = const PeerReadState();
      s = s.recordPeerRead(_peerId, 7).state;
      final lateFrame =
          _msg(id: '7', authorId: _selfId, status: types.Status.sent);
      final out = s.applyToMessage(lateFrame, _selfId) as types.TextMessage;
      expect(out.status, equals(types.Status.seen));
    });

    test('replay of older messages after the marker advanced keeps '
        'Status.seen — does not regress to sent', () {
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 10});
      for (final seq in [1, 2, 3, 4, 5]) {
        final m =
            _msg(id: '$seq', authorId: _selfId, status: types.Status.sent);
        final out = s.applyToMessage(m, _selfId) as types.TextMessage;
        expect(out.status, equals(types.Status.seen),
            reason: 'replay of seq $seq after peer-read=10 must be seen');
      }
    });

    test('mixed list scan: only own messages at-or-below get stamped', () {
      const s = PeerReadState(peerReadSeqByUser: {_peerId: 5});
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
          equals(types.Status.seen));
      expect(identical(stamped[1], list[1]), isTrue);
      expect(identical(stamped[2], list[2]), isTrue);
      expect((stamped[3] as types.TextMessage).status,
          equals(types.Status.seen));
      expect(identical(stamped[4], list[4]), isTrue);
      expect(identical(stamped[5], list[5]), isTrue);
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

    test('null selfId → no filter', () {
      expect(
        PeerReadState.maxPeerRead(
          [_sub(_selfId, 100), _sub(_peerId, 5)],
          null,
        ),
        equals(100),
      );
    });
  });

  group('peerReadSeqsByUser', () {
    TopicSubscription _sub(String user, int? read) =>
        TopicSubscription(user: user, read: read);

    test('empty subscribers → empty map', () {
      expect(PeerReadState.peerReadSeqsByUser(const [], _selfId),
          equals({}));
    });

    test('excludes self', () {
      expect(
        PeerReadState.peerReadSeqsByUser(
          [_sub(_selfId, 10), _sub(_peerId, 5)],
          _selfId,
        ),
        equals({_peerId: 5}),
      );
    });

    test('multiple peers preserved verbatim', () {
      expect(
        PeerReadState.peerReadSeqsByUser(
          [_sub(_peerId, 3), _sub(_peerId2, 9), _sub(_peerId3, 5)],
          _selfId,
        ),
        equals({_peerId: 3, _peerId2: 9, _peerId3: 5}),
      );
    });

    test('null read excluded', () {
      expect(
        PeerReadState.peerReadSeqsByUser(
          [_sub(_peerId, null), _sub(_peerId2, 4)],
          _selfId,
        ),
        equals({_peerId2: 4}),
      );
    });

    test('zero read excluded', () {
      expect(
        PeerReadState.peerReadSeqsByUser(
          [_sub(_peerId, 0), _sub(_peerId2, 4)],
          _selfId,
        ),
        equals({_peerId2: 4}),
      );
    });

    test('null user-id excluded', () {
      expect(
        PeerReadState.peerReadSeqsByUser(
          [_sub('', 5)..user = null, _sub(_peerId, 3)],
          _selfId,
        ),
        equals({_peerId: 3}),
      );
    });
  });
}
