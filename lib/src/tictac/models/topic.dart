import 'message_preview.dart';
import 'topic_type.dart';

class Topic {
  final String id;
  String? name;
  final TopicType type;
  List<String> memberAppUserIds;
  MessagePreview? lastMessage;
  int memberCount;

  Topic({
    required this.id,
    this.name,
    required this.type,
    this.memberAppUserIds = const [],
    this.lastMessage,
    this.memberCount = 0,
  });
}
