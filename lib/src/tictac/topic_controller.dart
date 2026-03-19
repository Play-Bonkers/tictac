import 'dart:async';
import 'dart:convert';

import 'package:tictac/tinode.dart' as tinode;
import 'package:tictac/src/tictac/identity/identity_resolver.dart';

/// Per-topic state manager for TicTac.
///
/// Wraps a Tinode Topic and provides a clean API for sending messages,
/// tracking members, typing indicators, and read receipts.
///
/// In a Flutter app, extend this with ChangeNotifier (or use with
/// ValueNotifier/Stream) for reactive UI updates.
///
/// No Tinode types are exposed in the public API.
class TopicController {
  final String topicId;
  final String userId;
  final IdentityResolver identityResolver;

  tinode.Topic? _topic;
  bool _connected = false;

  // Message list (newest first for display)
  final List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  // Member tracking
  final Map<String, ChatMember> _memberMap = {};
  Map<String, ChatMember> get memberMap => Map.unmodifiable(_memberMap);

  // Pending outbound messages (buffered when disconnected)
  final List<_PendingMessage> _pendingOutbound = [];

  // Typing state
  Timer? _typingClearTimer;
  String? _typingUserId;
  String? get typingUserId => _typingUserId;

  // Change notification callback (replaces ChangeNotifier for pure Dart)
  void Function()? onChanged;

  // Stream subscriptions
  StreamSubscription? _dataSub;
  StreamSubscription? _presSub;
  StreamSubscription? _infoSub;
  StreamSubscription? _metaSubSub;

  TopicController({
    required this.topicId,
    required this.userId,
    required this.identityResolver,
    this.onChanged,
  });

  /// Attach to a Tinode topic and start listening for events.
  void attachToTopic(tinode.Topic topic) {
    _topic = topic;
    _connected = true;

    _dataSub?.cancel();
    _dataSub = topic.onData.listen(_handleData);

    _presSub?.cancel();
    _presSub = topic.onPres.listen(_handlePres);

    _infoSub?.cancel();
    _infoSub = topic.onInfo.listen(_handleInfo);

    _metaSubSub?.cancel();
    _metaSubSub = topic.onMetaSub.listen(_handleMetaSub);
  }

  bool get isConnected => _connected;

  void setConnected(bool connected) {
    _connected = connected;
    if (connected) {
      _flushPendingOutbound();
    }
    _notifyChanged();
  }

  // ---------------------------------------------------------------------------
  // Send operations
  // ---------------------------------------------------------------------------

  /// Send a text message.
  Future<void> sendMessage(String text) async {
    if (_topic == null) return;

    final msg = _topic!.createMessage(text, true);

    // Optimistic insert
    _messages.insert(0, ChatMessage(
      id: 'pending-${DateTime.now().millisecondsSinceEpoch}',
      text: text,
      authorId: userId,
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
    ));
    _notifyChanged();

    if (!_connected) {
      _pendingOutbound.add(_PendingMessage(text: text));
      return;
    }

    try {
      await _topic!.publishMessage(msg);
      // The server echo arrives via onData → _handleData, which will
      // replace the optimistic message (matched by text + sending status).
    } catch (e) {
      if (_messages.isNotEmpty && _messages[0].status == MessageStatus.sending) {
        _messages[0] = _messages[0].copyWith(status: MessageStatus.error);
        _notifyChanged();
      }
    }
  }

  /// Send a custom-typed message with JSON payload.
  Future<void> sendCustomMessage(
    String customType,
    String payload,
    String fallbackText,
  ) async {
    final content = {
      'customType': customType,
      'payload': jsonDecode(payload),
      'fallbackText': fallbackText,
    };
    if (_topic == null) return;

    final msg = _topic!.createMessage(content, true);

    _messages.insert(0, ChatMessage(
      id: 'pending-${DateTime.now().millisecondsSinceEpoch}',
      text: fallbackText,
      authorId: userId,
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
      customType: customType,
      customPayload: payload,
    ));
    _notifyChanged();

    if (!_connected) {
      _pendingOutbound.add(_PendingMessage(content: content));
      return;
    }

    try {
      await _topic!.publishMessage(msg);
    } catch (_) {}
  }

  /// Delete a message by seq ID.
  Future<void> deleteMessage(int seqId) async {
    if (_topic == null) return;
    await _topic!.deleteMessages(
      [tinode.DelRange(low: seqId, hi: seqId + 1)],
      true,
    );
    _messages.removeWhere((m) => m.id == seqId.toString());
    _notifyChanged();
  }

  /// Send a typing indicator.
  void setTyping(bool isTyping) {
    if (_topic == null || !_connected) return;
    if (isTyping) {
      _topic!.noteKeyPress();
    }
  }

  /// Mark a message as read by seq ID.
  void markRead(int seqId) {
    if (_topic == null || !_connected) return;
    _topic!.noteRead(seqId);
  }

  // ---------------------------------------------------------------------------
  // Event handlers
  // ---------------------------------------------------------------------------

  void _handleData(tinode.DataMessage? data) {
    if (data == null) return;

    // Clear typing indicator if this message is from the typer
    if (_typingUserId != null) {
      _clearTyping();
    }

    // Convert to ChatMessage
    _resolveAuthor(data.from).then((authorId) {
      final message = ChatMessage(
        id: data.seq?.toString() ?? '',
        text: data.content is String ? data.content : '',
        authorId: authorId,
        timestamp: data.ts ?? DateTime.now(),
        status: MessageStatus.sent,
        customType: data.content is Map ? (data.content as Map)['customType'] : null,
        customPayload: data.content is Map
            ? jsonEncode((data.content as Map)['payload'])
            : null,
      );

      // Replace optimistic (pending) message if it matches by text + sending status
      final pendingIdx = _messages.indexWhere((m) =>
          m.status == MessageStatus.sending && m.text == message.text);
      if (pendingIdx >= 0) {
        _messages[pendingIdx] = message;
      } else {
        // Deduplicate by ID
        final existingIdx = _messages.indexWhere((m) => m.id == message.id);
        if (existingIdx >= 0) {
          _messages[existingIdx] = message;
        } else {
          _messages.insert(0, message);
        }
      }
      _notifyChanged();
    });
  }

  void _handlePres(tinode.PresMessage? pres) {
    if (pres == null) return;

    if (pres.what == 'on' || pres.what == 'off') {
      final tinodeUserId = pres.src;
      if (tinodeUserId != null && _memberMap.containsKey(tinodeUserId)) {
        _memberMap[tinodeUserId]!.isOnline = pres.what == 'on';
        _notifyChanged();
      }
    }
  }

  void _handleInfo(dynamic info) {
    if (info == null) return;

    // Handle typing ("kp" = key press)
    if (info is Map && info['what'] == 'kp') {
      final from = info['from'] as String?;
      if (from != null && from != userId) {
        _setTyping(from);
      }
    }
  }

  void _handleMetaSub(tinode.TopicSubscription sub) {
    if (sub.user == null) return;

    String? displayName;
    if (sub.public != null && sub.public is Map) {
      displayName = (sub.public as Map)['fn'];
    }

    _memberMap[sub.user!] = ChatMember(
      tinodeUserId: sub.user!,
      displayName: displayName,
      isOnline: sub.online ?? false,
    );

    // Seed identity resolver
    if (sub.public != null && sub.public is Map) {
      final appUserId = (sub.public as Map)['appUserId'];
      if (appUserId != null && appUserId is String) {
        identityResolver.addMapping(appUserId, sub.user!);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Typing indicator
  // ---------------------------------------------------------------------------

  void _setTyping(String fromUserId) {
    _typingUserId = fromUserId;
    _notifyChanged();

    _typingClearTimer?.cancel();
    _typingClearTimer = Timer(const Duration(seconds: 3), _clearTyping);
  }

  void _clearTyping() {
    _typingClearTimer?.cancel();
    _typingUserId = null;
    _notifyChanged();
  }

  // ---------------------------------------------------------------------------
  // Outbound buffer
  // ---------------------------------------------------------------------------

  void _flushPendingOutbound() {
    if (_topic == null) return;

    for (final pending in _pendingOutbound) {
      final content = pending.content ?? pending.text;
      if (content != null) {
        final msg = _topic!.createMessage(content, true);
        _topic!.publishMessage(msg);
      }
    }
    _pendingOutbound.clear();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<String> _resolveAuthor(String? tinodeUserId) async {
    if (tinodeUserId == null) return 'unknown';
    final appUserId = await identityResolver.reverseLookup(tinodeUserId);
    return appUserId ?? tinodeUserId;
  }

  void _notifyChanged() {
    onChanged?.call();
  }

  void dispose() {
    _dataSub?.cancel();
    _presSub?.cancel();
    _infoSub?.cancel();
    _metaSubSub?.cancel();
    _typingClearTimer?.cancel();
  }
}

// ---------------------------------------------------------------------------
// Internal models
// ---------------------------------------------------------------------------

enum MessageStatus { sending, sent, error }

class ChatMessage {
  final String id;
  final String text;
  final String authorId;
  final DateTime timestamp;
  final MessageStatus status;
  final String? customType;
  final String? customPayload;

  ChatMessage({
    required this.id,
    required this.text,
    required this.authorId,
    required this.timestamp,
    this.status = MessageStatus.sent,
    this.customType,
    this.customPayload,
  });

  ChatMessage copyWith({
    String? id,
    String? text,
    String? authorId,
    DateTime? timestamp,
    MessageStatus? status,
    String? customType,
    String? customPayload,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      text: text ?? this.text,
      authorId: authorId ?? this.authorId,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      customType: customType ?? this.customType,
      customPayload: customPayload ?? this.customPayload,
    );
  }
}

class ChatMember {
  final String tinodeUserId;
  String? displayName;
  bool isOnline;

  ChatMember({
    required this.tinodeUserId,
    this.displayName,
    this.isOnline = false,
  });
}

class _PendingMessage {
  final String? text;
  final dynamic content;

  _PendingMessage({this.text, this.content});
}
