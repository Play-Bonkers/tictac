import 'topic_type.dart';

class Topic {
  final String id;
  String? name;
  final TopicType type;
  List<String> memberAppUserIds;
  int memberCount;

  /// Unread message count for the current user (server seq minus read marker).
  int unreadCount;

  /// Last activity timestamp (Tinode `touched`) — for sorting / "last active".
  DateTime? lastActivity;

  Topic({
    required this.id,
    this.name,
    required this.type,
    this.memberAppUserIds = const [],
    this.memberCount = 0,
    this.unreadCount = 0,
    this.lastActivity,
  });
}
