import 'dart:async';
import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:uuid/uuid.dart';

import 'package:tictac/tinode.dart' as tinode;
import 'package:tictac/src/tictac/identity/identity_resolver.dart';

const _uuid = Uuid();

/// Per-topic state manager for TicTac.
///
/// Wraps a Tinode Topic and provides a clean API for sending messages,
/// tracking members, typing indicators, and read receipts.
///
/// Messages are stored as [types.Message] (flutter_chat_types) natively —
/// conversion from Tinode DataMessage happens once on arrival.
///
/// Extends [ChangeNotifier] for reactive Flutter UI updates.
class TopicController extends ChangeNotifier {
  final String topicId;
  final String userId;
  final IdentityResolver identityResolver;
  final types.User Function(String userId)? userResolver;

  static const _typingPlaceholderPrefix = 'typing-placeholder-';

  static String _typingPlaceholderId(String userId) =>
      '$_typingPlaceholderPrefix$userId';

  static bool isTypingPlaceholder(types.Message msg) =>
      msg is types.CustomMessage &&
      msg.metadata != null &&
      msg.metadata!['type'] == 'typing';

  tinode.Topic? _topic;
  bool _connected = false;
  late final types.User _user;

  // Message list (newest first for display)
  final List<types.Message> _messages = [];
  List<types.Message> get messages => List.unmodifiable(_messages);

  /// ID of the newest real message (first non-placeholder in list).
  String? get lastMessageId {
    for (final m in _messages) {
      if (!isTypingPlaceholder(m)) return m.id;
    }
    return null;
  }

  // Member tracking
  final Map<String, types.User> _memberMap = {};
  Map<String, types.User> get memberMap => Map.unmodifiable(_memberMap);

  // Presence tracking
  final Map<String, bool> _presenceMap = {};
  Map<String, bool> get presenceMap => Map.unmodifiable(_presenceMap);
  bool isOnline(String userId) => _presenceMap[userId] ?? false;

  // Typing state
  final List<types.User> _typingUsers = [];
  List<types.User> get typingUsers => List.unmodifiable(_typingUsers);
  final Map<String, Timer> _typingTimers = {};

  // Pending outbound messages (buffered when disconnected)
  final Set<String> _pendingClientIds = {};
  final List<_PendingMessage> _pendingOutbound = [];

  // Read receipt tracking
  String? _lastReadMessageId;

  // Stream subscriptions
  StreamSubscription? _dataSub;
  StreamSubscription? _presSub;
  StreamSubscription? _infoSub;
  StreamSubscription? _metaSubSub;

  /// Return a fallback app user ID for message author, or null to drop the message.
  final String? Function(String tinodeUserId, String topicId)? onUnresolvedMessageAuthor;

  /// Return a fallback app user ID for a member, or null to skip.
  final String? Function(String tinodeUserId, String topicId)? onUnresolvedMember;

  /// Return a fallback app user ID for a presence update, or null to skip.
  final String? Function(String tinodeUserId, bool isOnline)? onUnresolvedPresence;

  /// Return a fallback app user ID for a typing indicator, or null to skip.
  final String? Function(String tinodeUserId, String topicId)? onUnresolvedTyping;

  TopicController({
    required this.topicId,
    required this.userId,
    required this.identityResolver,
    this.userResolver,
    this.onUnresolvedMessageAuthor,
    this.onUnresolvedMember,
    this.onUnresolvedPresence,
    this.onUnresolvedTyping,
  }) {
    _user = _resolveUser(userId);
  }

  types.User _resolveUser(String id) {
    if (userResolver != null) return userResolver!(id);
    return types.User(id: id);
  }

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
    } else {
      // Clear stale typing state on disconnect
      for (final timer in _typingTimers.values) {
        timer.cancel();
      }
      _typingTimers.clear();
      _typingUsers.clear();
      _messages.removeWhere(isTypingPlaceholder);
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Send operations
  // ---------------------------------------------------------------------------

  /// Send a text message.
  Future<void> sendMessage(types.PartialText partial) async {
    if (_topic == null) return;

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
    notifyListeners();

    if (!_connected) {
      _pendingOutbound.add(_PendingMessage(clientId: clientId, partial: partial));
      return;
    }

    _sendTextToServer(clientId, partial);
  }

  void _sendTextToServer(String clientId, types.PartialText partial) {
    final msg = _topic!.createMessage(partial.text, true);
    _topic!.publishMessage(msg).then((_) {
      // Server echo arrives via onData → _handleData, which replaces optimistic
    }).catchError((e) {
      _pendingClientIds.remove(clientId);
      debugPrint('TicTac: Send error: $e');
      // Mark optimistic message as error
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
          notifyListeners();
        }
      }
    });
  }

  /// Send a custom-typed message with JSON payload.
  Future<void> sendCustomMessage(
    String customType,
    Map<String, dynamic> payload, {
    String? fallbackText,
  }) async {
    if (_topic == null) return;

    final clientId = _uuid.v4();

    final optimistic = types.CustomMessage(
      id: clientId,
      author: _user,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: types.Status.sending,
      metadata: {
        'customType': customType,
        'payload': payload,
        if (fallbackText != null) 'fallbackText': fallbackText,
      },
    );
    _messages.insert(0, optimistic);
    _pendingClientIds.add(clientId);
    notifyListeners();

    if (!_connected) {
      _pendingOutbound.add(_PendingMessage(
        clientId: clientId,
        customType: customType,
        payload: payload,
        fallbackText: fallbackText,
      ));
      return;
    }

    _sendCustomToServer(clientId, customType, payload, fallbackText);
  }

  void _sendCustomToServer(
    String clientId,
    String customType,
    Map<String, dynamic> payload,
    String? fallbackText,
  ) {
    final content = {
      'customType': customType,
      'payload': payload,
      'fallbackText': fallbackText ?? '',
    };
    final msg = _topic!.createMessage(content, true);
    _topic!.publishMessage(msg).then((_) {
      // Server echo arrives via onData
    }).catchError((e) {
      _pendingClientIds.remove(clientId);
      debugPrint('TicTac: Custom send error: $e');
    });
  }

  /// Edit a message by ID.
  void editMessage(String messageId, String newText) {
    // Tinode doesn't have native message editing — this is a no-op placeholder.
    // If needed, implement via custom protocol (e.g. delete + re-send, or
    // application-level edit metadata).
    debugPrint('TicTac: editMessage not supported by Tinode protocol');
  }

  /// Delete a message by seq ID.
  Future<void> deleteMessage(String messageId) async {
    if (_topic == null) return;

    final seqId = int.tryParse(messageId);
    if (seqId == null) return;

    final idx = _messages.indexWhere((m) => m.id == messageId);
    types.Message? removed;
    if (idx >= 0) {
      removed = _messages.removeAt(idx);
      notifyListeners();
    }

    try {
      await _topic!.deleteMessages(
        [tinode.DelRange(low: seqId, hi: seqId + 1)],
        true,
      );
    } catch (e) {
      debugPrint('TicTac: Delete error: $e');
      if (removed != null) {
        _messages.insert(idx.clamp(0, _messages.length), removed);
        notifyListeners();
      }
    }
  }

  /// Send a typing indicator.
  void setTyping(bool isTyping) {
    if (_topic == null || !_connected) return;
    if (isTyping) {
      _topic!.noteKeyPress();
    }
  }

  /// Mark a message as read by message ID (seq string).
  void markRead(String messageId) {
    if (_topic == null || !_connected) return;
    if (messageId == _lastReadMessageId) return;
    _lastReadMessageId = messageId;

    final seqId = int.tryParse(messageId);
    if (seqId != null) {
      _topic!.noteRead(seqId);
    }
  }

  // ---------------------------------------------------------------------------
  // Event handlers
  // ---------------------------------------------------------------------------

  void _handleData(tinode.DataMessage? data) {
    if (data == null) return;

    _resolveAuthor(data.from).then((resolvedId) {
      final appUserId = resolvedId ??
          onUnresolvedMessageAuthor?.call(data.from ?? '', topicId);
      if (appUserId == null) return;

      final author = _resolveUser(appUserId);
      final msgId = data.seq?.toString() ?? _uuid.v4();
      final isOwnMessage = appUserId == userId;

      // Skip if we already have a pending client message being replaced
      if (_pendingClientIds.contains(msgId)) return;

      // Convert to types.Message
      final types.Message message;
      if (data.content is Map) {
        final map = data.content as Map;
        if (map.containsKey('customType')) {
          message = types.CustomMessage(
            id: msgId,
            author: author,
            createdAt: data.ts?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
            status: isOwnMessage ? types.Status.sent : null,
            metadata: {
              'customType': map['customType'],
              if (map['payload'] != null) 'payload': map['payload'],
              if (map['fallbackText'] != null) 'fallbackText': map['fallbackText'],
            },
          );
        } else {
          message = types.TextMessage(
            id: msgId,
            author: author,
            text: data.content.toString(),
            createdAt: data.ts?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
            status: isOwnMessage ? types.Status.sent : null,
          );
        }
      } else {
        message = types.TextMessage(
          id: msgId,
          author: author,
          text: data.content?.toString() ?? '',
          createdAt: data.ts?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
          status: isOwnMessage ? types.Status.sent : null,
        );
      }

      // Clear typing state and placeholder for this author
      if (_typingUsers.any((u) => u.id == appUserId)) {
        _typingTimers[appUserId]?.cancel();
        _typingTimers.remove(appUserId);
        _typingUsers.removeWhere((u) => u.id == appUserId);
      }
      _messages.removeWhere(
        (m) => m.id == _typingPlaceholderId(appUserId),
      );

      // Replace optimistic (pending) message if matches by author + sending status
      if (isOwnMessage) {
        final pendingIdx = _messages.indexWhere((m) =>
            m.author.id == userId &&
            m.status == types.Status.sending &&
            _pendingClientIds.contains(m.id));
        if (pendingIdx >= 0) {
          _pendingClientIds.remove(_messages[pendingIdx].id);
          _messages[pendingIdx] = message;
          notifyListeners();
          return;
        }
      }

      // Deduplicate by ID
      final existingIdx = _messages.indexWhere((m) => m.id == message.id);
      if (existingIdx >= 0) {
        _messages[existingIdx] = message;
      } else {
        _insertInOrder(message);
      }

      // Track member
      if (!_memberMap.containsKey(appUserId)) {
        _memberMap[appUserId] = author;
      }

      notifyListeners();
    }).catchError((e) {
      debugPrint('TicTac: _handleData error: $e');
    });
  }

  void _handlePres(tinode.PresMessage? pres) {
    if (pres == null) return;

    if (pres.what == 'on' || pres.what == 'off') {
      final tinodeUserId = pres.src;
      if (tinodeUserId == null) return;

      identityResolver.reverseLookup(tinodeUserId).then((resolvedId) {
        final appUserId = resolvedId ??
            onUnresolvedPresence?.call(tinodeUserId, pres.what == 'on');
        if (appUserId == null) return;
        _presenceMap[appUserId] = pres.what == 'on';
        notifyListeners();
      }).catchError((e) {
        debugPrint('TicTac: _handlePres reverseLookup error: $e');
      });
    }
  }

  void _handleInfo(dynamic info) {
    if (info == null) return;

    // Handle typing ("kp" = key press)
    if (info is Map && info['what'] == 'kp') {
      final from = info['from'] as String?;
      if (from == null) return;

      // Resolve tinode user ID to app user ID
      identityResolver.reverseLookup(from).then((resolvedId) {
        final appUserId = resolvedId ??
            onUnresolvedTyping?.call(from, topicId);
        if (appUserId == null || appUserId == userId) return;
        _setTyping(appUserId);
      }).catchError((e) {
        debugPrint('TicTac: _handleInfo reverseLookup error: $e');
      });
    }
  }

  void _handleMetaSub(tinode.TopicSubscription sub) {
    if (sub.user == null) return;

    String? appUserId;
    if (sub.public != null && sub.public is Map) {
      appUserId = (sub.public as Map)['appUserId'];
    }

    // Seed identity resolver
    if (appUserId != null) {
      identityResolver.addMapping(appUserId, sub.user!);
    }

    appUserId ??= onUnresolvedMember?.call(sub.user!, topicId);
    if (appUserId == null) return;
    _memberMap[appUserId] = _resolveUser(appUserId);
    _presenceMap[appUserId] = sub.online ?? false;
  }

  // ---------------------------------------------------------------------------
  // Typing indicator
  // ---------------------------------------------------------------------------

  void _setTyping(String fromUserId) {
    if (!_typingUsers.any((u) => u.id == fromUserId)) {
      final member = _memberMap[fromUserId];
      final typingUser = member ?? types.User(id: fromUserId);
      _typingUsers.add(typingUser);

      // Insert typing placeholder message
      final placeholderId = _typingPlaceholderId(fromUserId);
      if (!_messages.any((m) => m.id == placeholderId)) {
        _messages.insert(0, types.CustomMessage(
          id: placeholderId,
          author: typingUser,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          metadata: const {'type': 'typing'},
        ));
      }
      notifyListeners();
    }

    _typingTimers[fromUserId]?.cancel();
    _typingTimers[fromUserId] = Timer(const Duration(seconds: 3), () {
      _removeTypingState(fromUserId);
    });
  }

  void _removeTypingState(String typingUserId) {
    _typingTimers[typingUserId]?.cancel();
    _typingTimers.remove(typingUserId);
    _typingUsers.removeWhere((u) => u.id == typingUserId);
    _messages.removeWhere((m) => m.id == _typingPlaceholderId(typingUserId));
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Outbound buffer
  // ---------------------------------------------------------------------------

  void _flushPendingOutbound() {
    final pending = List.of(_pendingOutbound);
    _pendingOutbound.clear();
    for (final msg in pending) {
      if (msg.isCustom) {
        _sendCustomToServer(
          msg.clientId, msg.customType!, msg.payload!, msg.fallbackText);
      } else if (msg.partial != null) {
        _sendTextToServer(msg.clientId, msg.partial!);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<String?> _resolveAuthor(String? tinodeUserId) async {
    if (tinodeUserId == null) return null;
    return await identityResolver.reverseLookup(tinodeUserId);
  }

  void _insertInOrder(types.Message msg) {
    final ts = msg.createdAt ?? 0;
    var i = 0;
    while (i < _messages.length && (_messages[i].createdAt ?? 0) > ts) {
      i++;
    }
    _messages.insert(i, msg);
  }

  @override
  void dispose() {
    _dataSub?.cancel();
    _presSub?.cancel();
    _infoSub?.cancel();
    _metaSubSub?.cancel();
    for (final timer in _typingTimers.values) {
      timer.cancel();
    }
    _typingTimers.clear();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Internal models
// ---------------------------------------------------------------------------

class _PendingMessage {
  final String clientId;
  final types.PartialText? partial;
  final String? customType;
  final Map<String, dynamic>? payload;
  final String? fallbackText;

  _PendingMessage({
    required this.clientId,
    this.partial,
    this.customType,
    this.payload,
    this.fallbackText,
  });

  bool get isCustom => customType != null;
}
