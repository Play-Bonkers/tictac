/// TicTac — Torpedo Internal Component for Text and Audio Chat.
///
/// Public API for consuming apps. No Tinode types are exported.
library tictac;

// Core
export 'src/tictac/tictac_module.dart' show TicTacModule;
export 'src/tictac/tictac_config.dart' show TicTacConfig;
export 'src/tictac/topic_controller.dart' show TopicController;

// Models (tictac's own types — no Tinode leakage)
export 'src/tictac/models/topic.dart' show Topic;
export 'src/tictac/models/topic_type.dart' show TopicType;
export 'src/tictac/models/member.dart' show Member;
export 'src/tictac/models/chat_presence_state.dart' show ChatPresenceState;
export 'src/tictac/models/message_preview.dart' show MessagePreview;

// Identity
export 'src/tictac/identity/identity_resolver.dart' show IdentityResolver;
export 'src/tictac/identity/cached_identity_resolver.dart'
    show CachedIdentityResolver;
export 'src/tictac/identity/tags_identity_resolver.dart'
    show TagsIdentityResolver;

// Widget layer
export 'src/tictac/tictac_chat.dart' show TicTacChat;
export 'src/tictac/typing_dots.dart' show TicTacTypingDots, TicTacTypingDotsOptions;
export 'src/tictac/message_actions.dart'
    show TicTacMessageActionsOptions, TicTacMessageActionItem, showTicTacMessageActions;
export 'src/tictac/user_avatar.dart' show TicTacUserAvatar;
export 'src/tictac/topic_avatar.dart' show TicTacTopicAvatar, TicTacTopicAvatarMember;
