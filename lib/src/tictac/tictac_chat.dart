// TicTacChat widget — wraps flutter_chat_ui with TopicController.
//
// This file requires Flutter dependencies (flutter_chat_ui, flutter_chat_types).
// Port from: chat-exchange-service/dart/cxs_flyer_lib/lib/src/cxs_chat_widget.dart
//
// Key features to port:
// - Takes TopicController as input
// - Wraps flutter_chat_ui Chat widget
// - Message actions menu (edit/delete) via long press
// - Typing dots animation (3 bouncing dots)
// - Edit mode banner
// - Auto markRead on message visibility
// - Auto typing event on text input (2s debounce)
// - Custom message builder pass-through
// - Server-driven display/input config (optional)
//
// Supporting widgets to port alongside:
// - TicTacTypingDots / TicTacTypingDotsOptions (from cxs_flyer_lib/typing_dots.dart)
// - TicTacMessageActionsOptions / TicTacMessageActionItem (from cxs_flyer_lib/message_actions.dart)
// - TicTacUserAvatar (from cxs_flyer_lib/cxs_user_avatar.dart)
// - TicTacTopicAvatar (from cxs_flyer_lib/cxs_topic_avatar.dart)
//
// TODO: Implement when Flutter dependencies are added to pubspec.yaml
