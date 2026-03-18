import 'chat_presence_state.dart';

class Member {
  final String appUserId;
  final String? displayName;
  ChatPresenceState presence;

  Member({
    required this.appUserId,
    this.displayName,
    this.presence = ChatPresenceState.unknown,
  });
}
