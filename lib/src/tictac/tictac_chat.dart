import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_ui/src/conditional/conditional.dart';
import 'package:flutter_chat_ui/src/models/date_header.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:intl/intl.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:uuid/uuid.dart';

import 'message_actions.dart';
import 'peer_read_state.dart';
import 'tictac_callbacks.dart';
import 'tictac_module.dart';
import 'topic_handle.dart';
import 'typing_dots.dart';
import 'user_avatar.dart';

const _uuid = Uuid();
const _typingPlaceholderPrefix = 'typing-placeholder-';
String _typingPlaceholderId(String userId) =>
    '$_typingPlaceholderPrefix$userId';
bool _isTypingPlaceholder(types.Message m) =>
    m is types.CustomMessage &&
    m.metadata != null &&
    m.metadata!['type'] == 'typing';

/// Drop-in chat widget that wraps `flutter_chat_ui`'s [Chat] for a given
/// topic.
///
/// Behavior:
/// * On mount, calls [TicTacModule.joinTopic] and registers an internal
///   [TicTacCallbacks] bag for the events it needs (`onMessageReceived`,
///   `onMemberAdded`, `onTopicPresenceChanged`, `onTypingStarted`,
///   `onMessageDeleted`).
/// * Accumulates messages, members, and presence into its own state and
///   pushes them into [Chat] on every change.
/// * Owns the optimistic-send → server-echo swap, the 3-second typing
///   auto-clear, and per-message read-receipt firing on visibility.
///
/// **What you can override.** All `flutter_chat_ui` [Chat] props are
/// forwarded — pass any builder, theme, or option to customize.
/// Pass `customMessageBuilder` to render your own custom message types.
///
/// **What you can not change here.** The state model (message list,
/// member map, presence, typing) is internal — if you need a different
/// shape, register your own callbacks on the module and build a
/// different UI.
class TicTacChat extends StatefulWidget {
  TicTacChat({
    required this.module,
    required this.topicId,
    // ---- TicTac-specific ----
    this.typingDotsOptions,
    this.messageActionsOptions,
    // ---- flutter_chat_ui pass-through ----
    this.audioMessageBuilder,
    this.avatarBuilder,
    this.userAvatarBuilder,
    this.bubbleBuilder,
    this.bubbleRtlAlignment,
    this.customBottomWidget,
    this.customDateHeaderText,
    this.customMessageBuilder,
    this.customStatusBuilder,
    this.dateFormat,
    this.dateHeaderBuilder,
    this.dateHeaderThreshold,
    this.dateIsUtc,
    this.dateLocale,
    this.disableImageGallery,
    this.emojiEnlargementBehavior,
    this.emptyState,
    this.fileMessageBuilder,
    this.groupMessagesThreshold,
    this.hideBackgroundOnEmojiMessages,
    this.imageGalleryOptions,
    this.imageHeaders,
    this.imageMessageBuilder,
    this.imageProviderBuilder,
    this.inputOptions,
    this.isAttachmentUploading,
    this.isLastPage,
    this.keyboardDismissBehavior,
    this.l10n,
    this.listBottomWidget,
    this.nameBuilder,
    this.onAttachmentPressed,
    this.onAvatarTap,
    this.onBackgroundTap,
    this.onEndReached,
    this.onEndReachedThreshold,
    this.onMessageDoubleTap,
    this.onMessageLongPress,
    this.onMessageStatusLongPress,
    this.onMessageStatusTap,
    this.onMessageTap,
    this.onMessageVisibilityChanged,
    this.onPreviewDataFetched,
    this.scrollController,
    this.scrollPhysics,
    this.scrollToUnreadOptions,
    this.showUserAvatars,
    this.showUserNames,
    this.systemMessageBuilder,
    this.textMessageBuilder,
    this.textMessageOptions,
    this.theme,
    this.timeFormat,
    this.typingIndicatorOptions,
    this.usePreviewData,
    this.userAgent,
    this.useTopSafeAreaInset,
    this.videoMessageBuilder,
    this.slidableMessageBuilder,
    this.isLeftStatus,
    this.messageWidthRatio,
    super.key,
  });

  final TicTacModule module;
  final String topicId;
  final TicTacTypingDotsOptions? typingDotsOptions;
  final TicTacMessageActionsOptions? messageActionsOptions;

  // ---- flutter_chat_ui pass-through params (all optional) ----

  final Widget Function(types.AudioMessage, {required int messageWidth})?
      audioMessageBuilder;
  final Widget Function(types.User author)? avatarBuilder;
  final Widget Function(String userId, bool isOnline)? userAvatarBuilder;
  final Widget Function(
    Widget child, {
    required types.Message message,
    required bool nextMessageInGroup,
  })? bubbleBuilder;
  final BubbleRtlAlignment? bubbleRtlAlignment;
  final Widget? customBottomWidget;
  final String Function(DateTime)? customDateHeaderText;
  final Widget Function(types.CustomMessage, {required int messageWidth})?
      customMessageBuilder;
  final Widget Function(types.Message message, {required BuildContext context})?
      customStatusBuilder;
  final DateFormat? dateFormat;
  final Widget Function(DateHeader)? dateHeaderBuilder;
  final int? dateHeaderThreshold;
  final bool? dateIsUtc;
  final String? dateLocale;
  final bool? disableImageGallery;
  final EmojiEnlargementBehavior? emojiEnlargementBehavior;
  final Widget? emptyState;
  final Widget Function(types.FileMessage, {required int messageWidth})?
      fileMessageBuilder;
  final int? groupMessagesThreshold;
  final bool? hideBackgroundOnEmojiMessages;
  final ImageGalleryOptions? imageGalleryOptions;
  final Map<String, String>? imageHeaders;
  final Widget Function(types.ImageMessage, {required int messageWidth})?
      imageMessageBuilder;
  final ImageProvider Function({
    required String uri,
    required Map<String, String>? imageHeaders,
    required Conditional conditional,
  })? imageProviderBuilder;
  final InputOptions? inputOptions;
  final bool? isAttachmentUploading;
  final bool? isLastPage;
  final ScrollViewKeyboardDismissBehavior? keyboardDismissBehavior;
  final ChatL10n? l10n;
  final Widget? listBottomWidget;
  final Widget Function(types.User)? nameBuilder;
  final VoidCallback? onAttachmentPressed;
  final void Function(types.User)? onAvatarTap;
  final VoidCallback? onBackgroundTap;
  final Future<void> Function()? onEndReached;
  final double? onEndReachedThreshold;
  final void Function(BuildContext context, types.Message)? onMessageDoubleTap;
  final void Function(BuildContext context, types.Message)? onMessageLongPress;
  final void Function(BuildContext context, types.Message)?
      onMessageStatusLongPress;
  final void Function(BuildContext context, types.Message)? onMessageStatusTap;
  final void Function(BuildContext context, types.Message)? onMessageTap;
  final void Function(types.Message, bool visible)? onMessageVisibilityChanged;
  final void Function(types.TextMessage, types.PreviewData)?
      onPreviewDataFetched;
  final AutoScrollController? scrollController;
  final ScrollPhysics? scrollPhysics;
  final ScrollToUnreadOptions? scrollToUnreadOptions;
  final bool? showUserAvatars;
  final bool? showUserNames;
  final Widget Function(types.SystemMessage)? systemMessageBuilder;
  final Widget Function(
    types.TextMessage, {
    required int messageWidth,
    required bool showName,
  })? textMessageBuilder;
  final TextMessageOptions? textMessageOptions;
  final ChatTheme? theme;
  final DateFormat? timeFormat;
  final TypingIndicatorOptions? typingIndicatorOptions;
  final bool? usePreviewData;
  final String? userAgent;
  final bool? useTopSafeAreaInset;
  final Widget Function(types.VideoMessage, {required int messageWidth})?
      videoMessageBuilder;
  final Widget Function(types.Message, Widget msgWidget)?
      slidableMessageBuilder;
  final bool? isLeftStatus;
  final double? messageWidthRatio;

  @override
  State<TicTacChat> createState() => _TicTacChatState();
}

class _TicTacChatState extends State<TicTacChat> {
  late final types.User _user;
  late final TextEditingController _inputController;
  Timer? _typingDebounce;
  bool _disposed = false;

  // Internal state — accumulates from callbacks on TicTacModule.
  final List<types.Message> _messages = [];     // newest-first
  final Map<String, types.User> _members = {};  // app user id → User
  final Map<String, bool> _presence = {};       // app user id → online
  final Set<String> _typingUserIds = {};
  final Map<String, Timer> _typingTimers = {};

  // Optimistic-send tracking: client-generated id → still pending?
  final Set<String> _pendingClientIds = {};

  TopicHandle? _topic;
  String? _lastReadMessageId;

  // Highest seq the peer has read. The `seen` upgrade lives only here in
  // this widget's list; Tinode replays `{data}` frames (reconnect catch-up,
  // resubscribe, joinTopic cache replay) and _buildMessage stamps
  // `Status.sent` on every own-message, which would clobber the seen
  // state. Caching the read marker lets _handleMessage re-apply seen on
  // every insert/replace, and lets _handleRead survive races where the
  // read marker arrives before its corresponding data message.
  PeerReadState _peerReadState = const PeerReadState();

  // Our callback bag — registered on the module via addCallbacks at
  // mount and removed on dispose. Holding by reference (not identity-
  // hashed) so removal hits the exact same instance.
  late final TicTacCallbacks _ownCallbacks;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController();
    _user = types.User(id: widget.module.config.appUserId);
    _ownCallbacks = TicTacCallbacks(
      onMessageReceived: (topicId, msg) {
        if (topicId == widget.topicId) _handleMessage(msg);
      },
      onMessageDeleted: (topicId, msgId) {
        if (topicId == widget.topicId) _handleMessageDeleted(msgId);
      },
      onMemberAdded: (topicId, member) {
        if (topicId == widget.topicId) _handleMemberAdded(member);
      },
      onMemberRemoved: (topicId, appUserId) {
        if (topicId == widget.topicId) _handleMemberRemoved(appUserId);
      },
      onTopicPresenceChanged: (topicId, appUserId, isOnline) {
        if (topicId == widget.topicId) _handlePresence(appUserId, isOnline);
      },
      onTypingStarted: (topicId, appUserId) {
        if (topicId == widget.topicId) _markTyping(appUserId);
      },
      onMessageRead: (topicId, appUserId, seq) {
        // _peerReadSeq drives the "seen" tick on OWN messages, which
        // only matters when the reader is NOT us. tictac now fires
        // onMessageRead for self reads as well (so host topic-list
        // caches can track "I've caught up"); filter those out here.
        if (topicId != widget.topicId) return;
        if (appUserId == widget.module.config.appUserId) return;
        _handleRead(seq);
      },
    );
    widget.module.addCallbacks(_ownCallbacks);
    _joinTopic();
  }

  Future<void> _joinTopic() async {
    final t = await widget.module.joinTopic(widget.topicId);
    if (_disposed) return;
    _topic = t;
    // Seed the peer-read marker from the topic's cached subscribers so
    // re-mounted chats can stamp Status.seen on replayed own-messages
    // without waiting for a live {info what=read}.
    final seq = t.peerReadSeq();
    if (seq > _peerReadState.peerReadSeq) _handleRead(seq);
  }

  @override
  void dispose() {
    _disposed = true;
    _typingDebounce?.cancel();
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    _typingTimers.clear();
    widget.module.removeCallbacks(_ownCallbacks);
    // Intentionally do NOT call _topic.leave() here. Topic lifecycle is
    // owned by the host (the bridge / app shell) — leaving on every
    // screen close churns the server with sub/leave/sub cycles that
    // either confuse the SDK or trip server-side abuse detection, and
    // makes re-entry slow because we re-subscribe each time. Keeping the
    // subscription alive means joinTopic on re-mount is a cache hit and
    // the chat repopulates instantly from tinode's local message cache.
    // _inputController is owned by flutter_chat_ui's Input — do not dispose
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Callback handlers
  // ---------------------------------------------------------------------------

  void _handleMessage(types.Message msg) {
    if (_disposed) return;

    msg = _applyPeerRead(msg);

    // Replace optimistic placeholder, if any.
    if (msg.author.id == _user.id) {
      final pending = _messages.indexWhere((m) =>
          m.author.id == _user.id &&
          m.status == types.Status.sending &&
          _pendingClientIds.contains(m.id));
      if (pending >= 0) {
        _pendingClientIds.remove(_messages[pending].id);
        _messages[pending] = msg;
        setState(() {});
        return;
      }
    }

    // Clear typing placeholder for this author.
    _typingUserIds.remove(msg.author.id);
    _typingTimers.remove(msg.author.id)?.cancel();
    _messages.removeWhere((m) => m.id == _typingPlaceholderId(msg.author.id));

    // Dedupe by id, insert newest-first.
    final idx = _messages.indexWhere((m) => m.id == msg.id);
    if (idx >= 0) {
      _messages[idx] = msg;
    } else {
      _insertInOrder(msg);
    }

    // Track member if we haven't seen them.
    _members.putIfAbsent(msg.author.id, () => msg.author);

    setState(() {});
  }

  void _handleMessageDeleted(String messageId) {
    final removed = _messages.length;
    _messages.removeWhere((m) => m.id == messageId);
    if (_messages.length != removed) setState(() {});
  }

  // A peer read up to [readSeq] (inclusive). Upgrade our own already-sent
  // messages at or below that seq to "seen" so flutter_chat_ui renders the
  // read checkmark. Optimistic placeholders have non-numeric (uuid) ids and
  // are skipped until their server echo replaces them.
  void _handleRead(int readSeq) {
    if (_disposed) return;
    _peerReadState = _peerReadState.recordPeerRead(readSeq).state;
    var changed = false;
    for (var i = 0; i < _messages.length; i++) {
      final updated = _peerReadState.applyToMessage(_messages[i], _user.id);
      if (!identical(updated, _messages[i])) {
        _messages[i] = updated;
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  // Stamp `Status.seen` on own messages already covered by the peer's
  // read marker. Called on every insert/replace so re-deliveries and
  // late-arriving data frames don't downgrade to `Status.sent`.
  types.Message _applyPeerRead(types.Message msg) =>
      _peerReadState.applyToMessage(msg, _user.id);

  void _handleMemberAdded(types.User member) {
    if (_members[member.id] != null) return;
    _members[member.id] = member;
    setState(() {});
  }

  void _handleMemberRemoved(String appUserId) {
    if (_members.remove(appUserId) != null) {
      _presence.remove(appUserId);
      setState(() {});
    }
  }

  void _handlePresence(String appUserId, bool isOnline) {
    if (_presence[appUserId] == isOnline) return;
    _presence[appUserId] = isOnline;
    setState(() {});
  }

  void _markTyping(String appUserId) {
    if (appUserId == _user.id) return;

    final wasTyping = _typingUserIds.add(appUserId);
    final placeholderId = _typingPlaceholderId(appUserId);
    if (wasTyping && !_messages.any((m) => m.id == placeholderId)) {
      final user = _members[appUserId] ?? types.User(id: appUserId);
      _messages.insert(
        0,
        types.CustomMessage(
          id: placeholderId,
          author: user,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          metadata: const {'type': 'typing'},
        ),
      );
    }

    _typingTimers[appUserId]?.cancel();
    _typingTimers[appUserId] = Timer(const Duration(seconds: 3), () {
      _typingUserIds.remove(appUserId);
      _typingTimers.remove(appUserId);
      _messages.removeWhere((m) => m.id == placeholderId);
      if (mounted) setState(() {});
    });

    if (wasTyping) setState(() {});
  }

  void _insertInOrder(types.Message msg) {
    final ts = msg.createdAt ?? 0;
    var i = 0;
    while (i < _messages.length && (_messages[i].createdAt ?? 0) > ts) {
      i++;
    }
    _messages.insert(i, msg);
  }

  // ---------------------------------------------------------------------------
  // Send
  // ---------------------------------------------------------------------------

  void _handleSend(types.PartialText partial) {
    final topic = _topic;
    if (topic == null) return;

    final clientId = _uuid.v4();
    final optimistic = types.TextMessage(
      id: clientId,
      author: _user,
      text: partial.text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: types.Status.sending,
    );
    _messages.insert(0, optimistic);
    _pendingClientIds.add(clientId);
    setState(() {});

    topic.sendText(partial.text).catchError((e) {
      _pendingClientIds.remove(clientId);
      final idx = _messages.indexWhere((m) => m.id == clientId);
      if (idx >= 0) {
        final orig = _messages[idx];
        if (orig is types.TextMessage) {
          _messages[idx] = types.TextMessage(
            id: orig.id,
            author: orig.author,
            text: orig.text,
            createdAt: orig.createdAt,
            status: types.Status.error,
          );
          if (mounted) setState(() {});
        }
      }
      debugPrint('TicTacChat: send error: $e');
    });
  }

  void _onTextChangedWithTyping(String text) {
    _topic?.setTyping(true);
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(seconds: 2), () {
      // Tinode has no "stop typing" event; nothing to send. The peer
      // side clears its placeholder on its own 3s timer.
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Chat(
      messages: _messages,
      user: _user,
      onSendPressed: _handleSend,
      showUserAvatars: widget.showUserAvatars ?? false,
      showUserNames: widget.showUserNames ?? false,
      dateHeaderThreshold: widget.dateHeaderThreshold ?? 900000,
      groupMessagesThreshold: widget.groupMessagesThreshold ?? 60000,
      messageWidthRatio: widget.messageWidthRatio ?? 0.72,
      emojiEnlargementBehavior:
          widget.emojiEnlargementBehavior ?? EmojiEnlargementBehavior.multi,
      hideBackgroundOnEmojiMessages: widget.hideBackgroundOnEmojiMessages ?? true,
      dateFormat: widget.dateFormat,
      timeFormat: widget.timeFormat,
      useTopSafeAreaInset: widget.useTopSafeAreaInset,
      inputOptions: _buildInputOptions(),
      keyboardDismissBehavior: widget.keyboardDismissBehavior ??
          ScrollViewKeyboardDismissBehavior.manual,
      onAttachmentPressed: widget.onAttachmentPressed,
      disableImageGallery: widget.disableImageGallery,
      usePreviewData: widget.usePreviewData ?? true,
      theme: widget.theme ?? const DefaultChatTheme(),
      l10n: widget.l10n ?? const ChatL10nEn(),
      audioMessageBuilder: widget.audioMessageBuilder,
      avatarBuilder: widget.avatarBuilder ?? _buildDefaultAvatarBuilder(),
      bubbleBuilder: widget.bubbleBuilder,
      bubbleRtlAlignment: widget.bubbleRtlAlignment ?? BubbleRtlAlignment.right,
      customBottomWidget: widget.customBottomWidget,
      customDateHeaderText: widget.customDateHeaderText,
      customMessageBuilder: _wrapCustomMessageBuilder(),
      customStatusBuilder: widget.customStatusBuilder,
      dateHeaderBuilder: widget.dateHeaderBuilder,
      dateIsUtc: widget.dateIsUtc ?? false,
      dateLocale: widget.dateLocale,
      emptyState: widget.emptyState,
      fileMessageBuilder: widget.fileMessageBuilder,
      imageGalleryOptions:
          widget.imageGalleryOptions ?? const ImageGalleryOptions(),
      imageHeaders: widget.imageHeaders,
      imageMessageBuilder: widget.imageMessageBuilder,
      imageProviderBuilder: widget.imageProviderBuilder,
      isAttachmentUploading: widget.isAttachmentUploading,
      isLastPage: widget.isLastPage,
      listBottomWidget: widget.listBottomWidget,
      nameBuilder: widget.nameBuilder,
      onAvatarTap: widget.onAvatarTap,
      onBackgroundTap: widget.onBackgroundTap,
      onEndReached: widget.onEndReached,
      onEndReachedThreshold: widget.onEndReachedThreshold,
      onMessageDoubleTap: widget.onMessageDoubleTap,
      onMessageLongPress: _wrapMessageLongPress(),
      onMessageStatusLongPress: widget.onMessageStatusLongPress,
      onMessageStatusTap: widget.onMessageStatusTap,
      onMessageTap: widget.onMessageTap,
      onMessageVisibilityChanged: _wrapVisibilityChanged(),
      onPreviewDataFetched: widget.onPreviewDataFetched,
      scrollController: widget.scrollController,
      scrollPhysics: widget.scrollPhysics,
      scrollToUnreadOptions:
          widget.scrollToUnreadOptions ?? const ScrollToUnreadOptions(),
      systemMessageBuilder: widget.systemMessageBuilder,
      textMessageBuilder: widget.textMessageBuilder,
      textMessageOptions:
          widget.textMessageOptions ?? const TextMessageOptions(),
      typingIndicatorOptions: _buildTypingIndicatorOptions(),
      userAgent: widget.userAgent,
      videoMessageBuilder: widget.videoMessageBuilder,
      slidableMessageBuilder: widget.slidableMessageBuilder,
      isLeftStatus: widget.isLeftStatus ?? false,
    );
  }

  // ---------------------------------------------------------------------------
  // flutter_chat_ui hooks
  // ---------------------------------------------------------------------------

  Widget Function(types.User author)? _buildDefaultAvatarBuilder() {
    return (types.User author) {
      final isOnline = _presence[author.id] ?? false;
      if (widget.userAvatarBuilder != null) {
        return widget.userAvatarBuilder!(author.id, isOnline);
      }
      return TicTacUserAvatar(
        displayName: author.firstName,
        imageUrl: author.imageUrl,
        isOnline: isOnline,
        size: 32,
      );
    };
  }

  InputOptions _buildInputOptions() {
    if (widget.inputOptions != null) {
      final opts = widget.inputOptions!;
      return InputOptions(
        inputClearMode: opts.inputClearMode,
        keyboardType: opts.keyboardType,
        onTextChanged: (text) {
          opts.onTextChanged?.call(text);
          _onTextChangedWithTyping(text);
        },
        onTextFieldTap: opts.onTextFieldTap,
        sendButtonVisibilityMode: opts.sendButtonVisibilityMode,
        textEditingController: _inputController,
        autocorrect: opts.autocorrect,
        autofocus: opts.autofocus,
        enableSuggestions: opts.enableSuggestions,
        enabled: opts.enabled,
      );
    }
    return InputOptions(
      onTextChanged: _onTextChangedWithTyping,
      textEditingController: _inputController,
    );
  }

  void Function(types.Message, bool)? _wrapVisibilityChanged() {
    return (types.Message message, bool visible) {
      widget.onMessageVisibilityChanged?.call(message, visible);
      if (visible &&
          message.author.id != _user.id &&
          !_isTypingPlaceholder(message)) {
        if (message.id != _lastReadMessageId) {
          _lastReadMessageId = message.id;
          _topic?.markRead(message.id);
        }
      }
    };
  }

  void Function(BuildContext, types.Message)? _wrapMessageLongPress() {
    if (widget.onMessageLongPress != null) return widget.onMessageLongPress;

    final opts =
        widget.messageActionsOptions ?? const TicTacMessageActionsOptions();
    if (!opts.enabled) return null;
    final topic = _topic;
    if (topic == null) return null;

    return (BuildContext ctx, types.Message message) {
      showTicTacMessageActions(
        context: ctx,
        message: message,
        topic: topic,
        currentUserId: _user.id,
        options: opts,
      );
    };
  }

  Widget Function(types.CustomMessage, {required int messageWidth})?
      _wrapCustomMessageBuilder() {
    final dotsOpts = widget.typingDotsOptions ?? const TicTacTypingDotsOptions();
    if (!dotsOpts.enabled) return widget.customMessageBuilder;

    return (types.CustomMessage message, {required int messageWidth}) {
      if (message.metadata?['type'] == 'typing') {
        if (dotsOpts.builder != null) {
          return dotsOpts.builder!(context, message);
        }
        return TicTacTypingDots(options: dotsOpts);
      }
      return widget.customMessageBuilder
              ?.call(message, messageWidth: messageWidth) ??
          const SizedBox.shrink();
    };
  }

  TypingIndicatorOptions _buildTypingIndicatorOptions() {
    final users = _typingUserIds
        .map((id) => _members[id] ?? types.User(id: id))
        .toList(growable: false);
    final dotsEnabled =
        (widget.typingDotsOptions ?? const TicTacTypingDotsOptions()).enabled;

    final suppressBuilder = dotsEnabled
        ? ({
            required BuildContext context,
            required BubbleRtlAlignment bubbleAlignment,
            required TypingIndicatorOptions options,
            required bool indicatorOnScrollStatus,
          }) =>
            const SizedBox.shrink()
        : null;

    if (widget.typingIndicatorOptions != null) {
      final opts = widget.typingIndicatorOptions!;
      return TypingIndicatorOptions(
        animationSpeed: opts.animationSpeed,
        customTypingIndicator: opts.customTypingIndicator,
        typingMode: opts.typingMode,
        typingUsers: users,
        customTypingWidget: opts.customTypingWidget,
        customTypingIndicatorBuilder:
            suppressBuilder ?? opts.customTypingIndicatorBuilder,
        typingWidgetBuilder: opts.typingWidgetBuilder,
        multiUserTextBuilder: opts.multiUserTextBuilder,
      );
    }
    return TypingIndicatorOptions(
      typingUsers: users,
      customTypingIndicatorBuilder: suppressBuilder,
    );
  }
}
