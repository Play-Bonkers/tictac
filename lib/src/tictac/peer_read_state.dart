import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:tictac/src/models/topic-subscription.dart';

/// Pure-function model of a chat's "seen by peer" state for own messages.
///
/// Today the state is a single `peerReadSeq` integer — Tinode's p2p
/// model where one number covers the conversation. The class exists so
/// the [TicTacChat] widget's seen-stamping logic can be tested without
/// mounting the widget or wiring a fake [TicTacModule], and so the
/// per-member refactor planned in BNK-593 has a single contained
/// surface area to evolve.
///
/// Semantics preserved from the in-widget implementation:
///
/// - [recordPeerRead] advances monotonically — equal or lower seq is a
///   no-op (matches the prior `if (readSeq > _peerReadSeq) …`).
/// - [applyToMessage] stamps `Status.seen` only on the caller's own
///   messages whose seq id parses as `int <= peerReadSeq`. Non-numeric
///   ids (optimistic uuid placeholders), other authors' messages, and
///   anything already `Status.seen` pass through untouched.
/// - When `peerReadSeq == 0` no message can be covered, so
///   [applyToMessage] is a no-op — matches the prior early-return.
class PeerReadState {
  final int peerReadSeq;

  const PeerReadState({this.peerReadSeq = 0});

  /// Returns a state advanced to [seq] if it's strictly greater than
  /// the current marker; otherwise returns this instance. The
  /// `changed` flag tells the caller whether to re-stamp the message
  /// list.
  ({PeerReadState state, bool changed}) recordPeerRead(int seq) {
    if (seq <= peerReadSeq) return (state: this, changed: false);
    return (state: PeerReadState(peerReadSeq: seq), changed: true);
  }

  /// Pure transform: returns [msg] stamped with `Status.seen` when the
  /// peer-read marker covers it, otherwise returns [msg] unchanged.
  /// Use identity (`identical(out, msg)`) at the call site to skip
  /// rebuilds when nothing changed.
  types.Message applyToMessage(types.Message msg, String selfUserId) {
    if (peerReadSeq == 0) return msg;
    if (msg.author.id != selfUserId) return msg;
    if (msg.status == types.Status.seen) return msg;
    final seq = int.tryParse(msg.id);
    if (seq == null || seq > peerReadSeq) return msg;
    return msg.copyWith(status: types.Status.seen);
  }

  /// Returns the highest read marker across non-self subscribers, or 0
  /// if no peer has read anything (or only self has). Used by
  /// [TopicHandle.peerReadSeq] to seed a re-mounted UI's seen state
  /// synchronously, without waiting for the next live `{info what=read}`.
  ///
  /// `null` or zero read markers count as "no signal" and are skipped.
  /// When [selfId] is null (e.g. SDK not authenticated yet) the filter
  /// degenerates and every subscriber is considered — matches the
  /// pre-extraction behaviour where the early-init path counted reads
  /// from everyone including, transiently, ourselves.
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
}
