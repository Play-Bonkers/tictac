import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import 'package:tictac/src/models/topic-subscription.dart';

/// Per-member "seen by peer" model for own messages.
///
/// Tracks read markers keyed by `appUserId`. The class is purely
/// functional — it doesn't know which users are members of the topic.
/// Callers (the widget, the host) own the roster and tell this class:
///
/// - "peer `X` read up to seq N" via [recordPeerRead]
/// - "is message [msg] seen?" via [applyToMessage], passing the topic's
///   semantic mode (p2p vs. group-all-members) at the call site
///
/// **p2p semantic** ([requireAllOf] == null): a message is seen as soon
/// as any peer's marker covers it. Matches the BNK-593-prep contract:
/// for a 1:1 chat, "seen" = "they read it."
///
/// **group semantic** ([requireAllOf] non-null): a message is seen only
/// when every user in [requireAllOf] has a marker that covers it.
/// Members absent from [peerReadSeqByUser] are treated as having not
/// read — a deliberate conservative choice so the blue tick doesn't
/// light up until every expected reader has actually arrived. The
/// caller is responsible for passing the *current* non-self roster;
/// members who joined after the message was sent are still required
/// (matches user expectations: "everyone in this chat now").
class PeerReadState {
  final Map<String, int> peerReadSeqByUser;

  const PeerReadState({this.peerReadSeqByUser = const {}});

  /// Returns the highest [seq] recorded for any peer, or 0 if none.
  /// Convenience for p2p call sites and the back-compat
  /// `TopicHandle.peerReadSeq()` shim — equivalent to "max over
  /// [peerReadSeqByUser]'s values."
  int get maxSeq {
    if (peerReadSeqByUser.isEmpty) return 0;
    return peerReadSeqByUser.values.reduce((a, b) => a > b ? a : b);
  }

  /// Returns a state with [userId]'s marker advanced to [seq] if it's
  /// strictly greater than the current value (or no prior value). Lower
  /// or equal markers are no-ops — peer reads only ever advance, in
  /// step with Tinode's `{info what=read}` semantics. The `changed`
  /// flag tells the caller whether to re-stamp the message list.
  ({PeerReadState state, bool changed}) recordPeerRead(
      String userId, int seq) {
    final existing = peerReadSeqByUser[userId] ?? 0;
    if (seq <= existing) return (state: this, changed: false);
    return (
      state: PeerReadState(
        peerReadSeqByUser: {...peerReadSeqByUser, userId: seq},
      ),
      changed: true,
    );
  }

  /// Pure transform: returns [msg] stamped with `Status.seen` when the
  /// peer-read marker covers it according to the topic's semantic mode,
  /// otherwise returns [msg] unchanged.
  ///
  /// - [selfUserId]: the local user; we never stamp messages we authored
  ///   ourselves with a "peer has seen" tick.
  /// - [requireAllOf]: pass `null` for p2p ("any peer's marker covers")
  ///   or a non-empty set for groups ("every listed peer must cover").
  ///   An empty set is treated as "no one expected to read" → never
  ///   seen, which matches the conservative product semantic for an
  ///   empty group.
  ///
  /// Use identity (`identical(out, msg)`) at the call site to skip
  /// rebuilds when nothing changed.
  types.Message applyToMessage(
    types.Message msg,
    String selfUserId, {
    Set<String>? requireAllOf,
  }) {
    if (msg.author.id != selfUserId) return msg;
    if (msg.status == types.Status.seen) return msg;
    final seq = int.tryParse(msg.id);
    if (seq == null) return msg;
    if (!_covered(seq, requireAllOf: requireAllOf)) return msg;
    return msg.copyWith(status: types.Status.seen);
  }

  /// True when the message at [msgSeq] is "seen" under the current
  /// mode. Public so callers can drive their own list walks (e.g.
  /// host code re-stamping `BonkersTopic.lastText`) without going
  /// through [applyToMessage]'s author/status guards.
  bool isCovered(int msgSeq, {Set<String>? requireAllOf}) =>
      _covered(msgSeq, requireAllOf: requireAllOf);

  bool _covered(int msgSeq, {Set<String>? requireAllOf}) {
    if (requireAllOf == null) {
      // p2p: any peer's marker covers.
      if (peerReadSeqByUser.isEmpty) return false;
      return peerReadSeqByUser.values.any((seq) => seq >= msgSeq);
    }
    // group: every expected peer must cover. Missing markers count
    // as "not read" → 0 → never covers a positive [msgSeq].
    if (requireAllOf.isEmpty) return false;
    for (final id in requireAllOf) {
      final seq = peerReadSeqByUser[id] ?? 0;
      if (seq < msgSeq) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------
  // Subscriber-level helpers
  // ---------------------------------------------------------------------

  /// Returns the highest read marker across non-self subscribers, or 0
  /// if no peer has read anything (or only self has). Used by
  /// [TopicHandle.peerReadSeq] to seed a re-mounted UI's seen state
  /// synchronously when the host only needs the p2p single-int view.
  ///
  /// `null` or zero read markers count as "no signal" and are skipped.
  /// When [selfId] is null (e.g. SDK not authenticated yet) the filter
  /// degenerates and every subscriber is considered.
  static int maxPeerRead(
    Iterable<TopicSubscription> subscribers,
    String? selfId,
  ) {
    var max = 0;
    for (final sub in subscribers) {
      final r = sub.read;
      if (r == null || r <= 0) continue;
      if (selfId != null && sub.user == selfId) continue;
      if (r > max) max = r;
    }
    return max;
  }

  /// Per-user view of [maxPeerRead], used by
  /// [TopicHandle.peerReadSeqs] to seed group chat state. Returns a
  /// map keyed by Tinode user id with the subscriber's read marker.
  /// Same filter semantics as [maxPeerRead] — null/zero reads and the
  /// self entry are skipped.
  static Map<String, int> peerReadSeqsByUser(
    Iterable<TopicSubscription> subscribers,
    String? selfId,
  ) {
    final out = <String, int>{};
    for (final sub in subscribers) {
      final user = sub.user;
      final r = sub.read;
      if (user == null) continue;
      if (r == null || r <= 0) continue;
      if (selfId != null && user == selfId) continue;
      out[user] = r;
    }
    return out;
  }
}
