import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_ui/src/conditional/conditional.dart';
import 'package:flutter_chat_ui/src/models/date_header.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:intl/intl.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import 'topic_controller.dart';
import 'user_avatar.dart';
import 'message_actions.dart';
import 'typing_dots.dart';

class TicTacChat extends StatefulWidget {
  TicTacChat({
    required this.controller,
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

  final TopicController controller;
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
  TopicController get _controller => widget.controller;
  late final types.User _user;
  Timer? _typingDebounce;
  bool _disposed = false;

  late final TextEditingController _inputController;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController();
    _controller.addListener(_onControllerChanged);
    _user = types.User(id: _controller.userId);
  }

  @override
  void dispose() {
    _disposed = true;
    _typingDebounce?.cancel();
    _controller.removeListener(_onControllerChanged);
    // Don't dispose _inputController — flutter_chat_ui's Input widget
    // takes ownership and disposes it during its own unmount.
    super.dispose();
  }

  void _onControllerChanged() {
    if (!_disposed && mounted) {
      setState(() {});
    }
  }

  // ---------------------------------------------------------------------------
  // Send
  // ---------------------------------------------------------------------------

  void _handleSend(types.PartialText partial) {
    _controller.sendMessage(partial);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Chat(
      messages: _controller.messages,
      user: _user,
      onSendPressed: _handleSend,
      // -- Defaults --
      showUserAvatars: widget.showUserAvatars ?? false,
      showUserNames: widget.showUserNames ?? false,
      dateHeaderThreshold: widget.dateHeaderThreshold ?? 900000,
      groupMessagesThreshold: widget.groupMessagesThreshold ?? 60000,
      messageWidthRatio: widget.messageWidthRatio ?? 0.72,
      emojiEnlargementBehavior:
          widget.emojiEnlargementBehavior ?? EmojiEnlargementBehavior.multi,
      hideBackgroundOnEmojiMessages:
          widget.hideBackgroundOnEmojiMessages ?? true,
      dateFormat: widget.dateFormat,
      timeFormat: widget.timeFormat,
      useTopSafeAreaInset: widget.useTopSafeAreaInset,
      // -- Input --
      inputOptions: _buildInputOptions(),
      keyboardDismissBehavior: widget.keyboardDismissBehavior ??
          ScrollViewKeyboardDismissBehavior.manual,
      // -- Features --
      onAttachmentPressed: widget.onAttachmentPressed,
      disableImageGallery: widget.disableImageGallery,
      usePreviewData: widget.usePreviewData ?? true,
      // -- Theme --
      theme: widget.theme ?? const DefaultChatTheme(),
      l10n: widget.l10n ?? const ChatL10nEn(),
      // -- Pass-through --
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
      imageGalleryOptions: widget.imageGalleryOptions ?? const ImageGalleryOptions(),
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
  // Avatar builder
  // ---------------------------------------------------------------------------

  Widget Function(types.User author)? _buildDefaultAvatarBuilder() {
    return (types.User author) {
      final isOnline = _controller.isOnline(author.id);
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

  // ---------------------------------------------------------------------------
  // Typing event on text change
  // ---------------------------------------------------------------------------

  void _onTextChangedWithTyping(String text) {
    _controller.setTyping(true);
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(seconds: 2), () {
      _controller.setTyping(false);
    });
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

  // ---------------------------------------------------------------------------
  // Visibility → markRead
  // ---------------------------------------------------------------------------

  void Function(types.Message, bool)? _wrapVisibilityChanged() {
    return (types.Message message, bool visible) {
      widget.onMessageVisibilityChanged?.call(message, visible);
      if (visible &&
          message.author.id != _user.id &&
          !TopicController.isTypingPlaceholder(message)) {
        _controller.markRead(message.id);
      }
    };
  }

  // ---------------------------------------------------------------------------
  // Long press → message actions
  // ---------------------------------------------------------------------------

  void Function(BuildContext, types.Message)? _wrapMessageLongPress() {
    if (widget.onMessageLongPress != null) return widget.onMessageLongPress;

    final opts =
        widget.messageActionsOptions ?? const TicTacMessageActionsOptions();
    if (!opts.enabled) return null;

    return (BuildContext ctx, types.Message message) {
      showTicTacMessageActions(
        context: ctx,
        message: message,
        controller: _controller,
        currentUserId: _user.id,
        options: opts,
      );
    };
  }

  // ---------------------------------------------------------------------------
  // Custom message builder (typing dots)
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Typing indicator options
  // ---------------------------------------------------------------------------

  TypingIndicatorOptions _buildTypingIndicatorOptions() {
    final users = _controller.typingUsers;
    final dotsEnabled =
        (widget.typingDotsOptions ?? const TicTacTypingDotsOptions()).enabled;

    // Suppress the built-in typing indicator when placeholder dots are active
    Widget Function({
      required BuildContext context,
      required BubbleRtlAlignment bubbleAlignment,
      required TypingIndicatorOptions options,
      required bool indicatorOnScrollStatus,
    })? suppressBuilder = dotsEnabled
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
