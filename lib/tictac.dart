/// TicTac — Torpedo Internal Component for Text and Audio Chat.
///
/// Public API for consuming apps. No Tinode types are exported.
///
/// See `INTEGRATION.md` for the full wiring guide.
library tictac;

// Core
export 'src/tictac/tictac_module.dart' show TicTacModule;
export 'src/tictac/tictac_config.dart' show TicTacConfig;
export 'src/tictac/tictac_callbacks.dart' show TicTacCallbacks;
export 'src/tictac/topic_handle.dart' show TopicHandle;
export 'src/tictac/connection_state.dart' show TicTacConnectionState;

// Models (tictac's own types — no Tinode leakage)
export 'src/tictac/models/topic.dart' show Topic;
export 'src/tictac/models/topic_type.dart' show TopicType;
export 'src/tictac/models/member.dart' show Member;
export 'src/tictac/models/chat_presence_state.dart' show ChatPresenceState;
export 'src/tictac/models/message_preview.dart' show MessagePreview;

// Voice (LiveKit)
export 'src/tictac/voice/voice_module.dart' show VoiceTokenException;
export 'src/tictac/voice/voice_session.dart' show VoiceSession;
export 'src/tictac/voice/voice_callbacks.dart' show VoiceCallbacks;
export 'src/tictac/voice/voice_participant.dart' show VoiceParticipant;

// Widget layer — opt-in convenience for flutter_chat_ui callers.
export 'src/tictac/tictac_chat.dart' show TicTacChat;
export 'src/tictac/typing_dots.dart'
    show TicTacTypingDots, TicTacTypingDotsOptions;
export 'src/tictac/message_actions.dart'
    show
        TicTacMessageActionsOptions,
        TicTacMessageActionItem,
        showTicTacMessageActions;
export 'src/tictac/user_avatar.dart' show TicTacUserAvatar;
export 'src/tictac/topic_avatar.dart'
    show TicTacTopicAvatar, TicTacTopicAvatarMember;
