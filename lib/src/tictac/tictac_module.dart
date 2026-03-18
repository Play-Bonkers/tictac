import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:tictac/tinode.dart' as tinode;
import 'package:tictac/src/models/rest-auth-secret.dart';
import 'package:tictac/src/tictac/tictac_config.dart';
import 'package:tictac/src/tictac/models/topic.dart' as tictac_models;
import 'package:tictac/src/tictac/models/topic_type.dart';
import 'package:tictac/src/tictac/models/message_preview.dart';
import 'package:tictac/src/tictac/identity/identity_resolver.dart';
import 'package:tictac/src/tictac/identity/cached_identity_resolver.dart';

/// Main entry point for TicTac chat functionality.
///
/// Wraps the Tinode SDK and exposes a clean API that matches the
/// CxsChatModule pattern. No Tinode types are exposed.
class TicTacModule {
  final TicTacConfig config;

  // ---------------------------------------------------------------------------
  // Consumer callbacks
  // ---------------------------------------------------------------------------

  void Function(List<tictac_models.Topic> topics)? onConnected;
  void Function(String reason)? onDisconnected;
  void Function(tictac_models.Topic topic)? onTopicAdded;
  void Function(String topicId, String reason)? onTopicRemoved;
  void Function(tictac_models.Topic topic)? onTopicUpdated;
  void Function(String userId, bool isOnline)? onPresenceChanged;
  void Function(String topicId)? onMessageReceived;

  // ---------------------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------------------

  tinode.Tinode? _tinode;
  tinode.AuthToken? _cachedToken;
  bool _intentionalDisconnect = false;
  bool _isReconnecting = false;
  int _reconnectAttempts = 0;
  DateTime? _firstFailureTime;
  final _random = Random();

  final Map<String, bool> _presenceMap = {};
  late IdentityResolver identityResolver;

  StreamSubscription? _onDisconnectSub;
  StreamSubscription? _onPressSub;
  StreamSubscription? _onSubsUpdatedSub;

  TicTacModule(
    this.config, {
    this.onConnected,
    this.onDisconnected,
    this.onTopicAdded,
    this.onTopicRemoved,
    this.onTopicUpdated,
    this.onPresenceChanged,
    this.onMessageReceived,
    IdentityResolver? identityResolver,
  }) {
    this.identityResolver = identityResolver ?? CachedIdentityResolver();
  }

  /// Check if a user is online.
  bool isOnline(String appUserId) => _presenceMap[appUserId] ?? false;

  /// Whether we're currently connected and authenticated.
  bool get isConnected => _tinode?.isConnected ?? false;

  // ---------------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------------

  /// Connect to Tinode, authenticate, and return the user's topic list.
  Future<List<tictac_models.Topic>> connect() async {
    _intentionalDisconnect = false;

    try {
      _tinode = tinode.Tinode(
        'TicTac/1.0',
        tinode.ConnectionOptions(
          config.wsHostPort,
          config.apiKey,
          secure: config.secure,
        ),
        false,
      );

      // Listen for disconnects
      _onDisconnectSub?.cancel();
      _onDisconnectSub = _tinode!.onDisconnect.listen((_) {
        if (_intentionalDisconnect) return;
        _log('Disconnected unexpectedly');
        onDisconnected?.call('Connection lost');
        _scheduleReconnect();
      });

      await _tinode!.connect();
      _log('Connected to ${config.wsHostPort}');

      // Authenticate
      await _authenticate();
      _log('Authenticated as ${_tinode!.userId}');

      // Seed identity resolver with current user
      identityResolver.addMapping(config.appUserId, _tinode!.userId);

      // Subscribe to "me" topic to get contact list and presence
      final me = _tinode!.getMeTopic();

      // Listen for presence changes
      _onPressSub?.cancel();
      _onPressSub = me.onPres.listen(_handlePresence);

      // Listen for subscription updates (topic list changes)
      _onSubsUpdatedSub?.cancel();
      _onSubsUpdatedSub = me.onSubsUpdated.listen(_handleSubsUpdated);

      await me.subscribe(
        tinode.MetaGetBuilder(me).withLaterSub(null).build(),
        null,
      );

      // Build topic list from "me" contacts
      final topics = await _buildTopicList(me);

      // Reset reconnect state on success
      _reconnectAttempts = 0;
      _isReconnecting = false;
      _firstFailureTime = null;

      onConnected?.call(topics);
      return topics;
    } catch (e) {
      _log('Connection failed: $e');
      onDisconnected?.call('Connection failed: $e');
      _scheduleReconnect();
      rethrow;
    }
  }

  /// Disconnect from Tinode.
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _onDisconnectSub?.cancel();
    _onPressSub?.cancel();
    _onSubsUpdatedSub?.cancel();
    _tinode?.disconnect();
    _tinode = null;
    _presenceMap.clear();
  }

  /// Force a reconnection (resets backoff state).
  void reconnect() {
    _reconnectAttempts = 0;
    _isReconnecting = false;
    _firstFailureTime = null;
    _smartReconnect();
  }

  void dispose() {
    disconnect();
  }

  // ---------------------------------------------------------------------------
  // Authentication
  // ---------------------------------------------------------------------------

  Future<void> _authenticate() async {
    // Fast path: try cached token
    if (_cachedToken != null &&
        _cachedToken!.token.isNotEmpty &&
        _cachedToken!.expires.isAfter(DateTime.now())) {
      try {
        await _tinode!.loginToken(_cachedToken!.token, {});
        return;
      } catch (_) {
        _log('Token login failed, falling back to REST auth');
        _cachedToken = null;
      }
    }

    // Full path: REST auth with protobuf secret
    final secret = RestAuthSecret(
      appUserId: config.appUserId,
      appId: config.appId,
      appKey: config.appKey,
    );
    final encodedSecret = base64.encode(secret.toBytes());

    await _tinode!.login('rest', encodedSecret, null);
    _cachedToken = _tinode!.getAuthenticationToken();
  }

  // ---------------------------------------------------------------------------
  // Topic operations
  // ---------------------------------------------------------------------------

  /// Get the current list of topics from the "me" subscription.
  Future<List<tictac_models.Topic>> getTopics() async {
    if (_tinode == null) throw StateError('Not connected');

    final me = _tinode!.getMeTopic();
    return _buildTopicList(me);
  }

  /// Create a group topic with the given name and members.
  Future<tictac_models.Topic> createGroupTopic(
    String name,
    List<String> memberAppUserIds,
  ) async {
    if (_tinode == null) throw StateError('Not connected');

    // Resolve app user IDs to tinode user IDs for invites
    final tinodeUserIds = <String>[];
    for (final appUserId in memberAppUserIds) {
      final tinodeId = await identityResolver.resolve(appUserId);
      if (tinodeId != null) {
        tinodeUserIds.add(tinodeId);
      }
    }

    final newTopic = _tinode!.newTopic();
    final setParams = tinode.SetParams();
    setParams.desc = tinode.TopicDescription();
    setParams.desc!.public = {'fn': name};

    await newTopic.subscribe(
      tinode.MetaGetBuilder(newTopic).build(),
      setParams,
    );

    // Invite members
    for (final userId in tinodeUserIds) {
      try {
        await newTopic.invite(userId, 'JRWPS');
      } catch (e) {
        _log('Failed to invite $userId: $e');
      }
    }

    return tictac_models.Topic(
      id: newTopic.name!,
      name: name,
      type: TopicType.group,
      memberAppUserIds: [config.appUserId, ...memberAppUserIds],
    );
  }

  /// Create a direct (P2P) topic with another user.
  Future<tictac_models.Topic> createDirectTopic(String otherAppUserId) async {
    if (_tinode == null) throw StateError('Not connected');

    final otherTinodeId = await identityResolver.resolve(otherAppUserId);
    if (otherTinodeId == null) {
      throw Exception('Cannot resolve user ID: $otherAppUserId');
    }

    final p2pTopic = _tinode!.newTopicWith(otherTinodeId);
    await p2pTopic.subscribe(
      tinode.MetaGetBuilder(p2pTopic).build(),
      null,
    );

    return tictac_models.Topic(
      id: p2pTopic.name!,
      name: otherAppUserId,
      type: TopicType.direct,
      memberAppUserIds: [config.appUserId, otherAppUserId],
    );
  }

  /// Delete a topic.
  Future<void> deleteTopic(String topicId, {bool hard = false}) async {
    if (_tinode == null) throw StateError('Not connected');
    await _tinode!.deleteTopic(topicId, hard);
  }

  /// Leave a topic (detach without deleting).
  Future<void> leaveTopic(String topicId) async {
    if (_tinode == null) throw StateError('Not connected');
    await _tinode!.leave(topicId, false);
  }

  // ---------------------------------------------------------------------------
  // Reconnection (two-phase with wall-clock limit)
  // ---------------------------------------------------------------------------

  Future<void> _smartReconnect() async {
    _intentionalDisconnect = false;

    try {
      // Clean up old connection
      _onDisconnectSub?.cancel();
      _onPressSub?.cancel();
      _onSubsUpdatedSub?.cancel();
      _tinode?.disconnect();
      _tinode = null;

      await connect();
    } catch (e) {
      _log('Reconnection failed: $e');
      // connect() already calls _scheduleReconnect on failure
    }
  }

  void _scheduleReconnect() {
    if (_intentionalDisconnect) return;
    if (_isReconnecting) return;

    _firstFailureTime ??= DateTime.now();

    final elapsed = DateTime.now().difference(_firstFailureTime!);
    if (elapsed >= config.maxReconnectDuration) {
      _log('Reconnect timeout — ${config.maxReconnectDuration.inMinutes}min elapsed');
      onDisconnected?.call(
        'Chat unavailable — could not reconnect after ${config.maxReconnectDuration.inMinutes} minutes',
      );
      return;
    }

    _isReconnecting = true;
    _reconnectAttempts++;

    final int baseDelayMs;
    if (_reconnectAttempts <= config.aggressiveAttempts) {
      final exponential = config.initialReconnectDelay.inMilliseconds *
          pow(2.0, _reconnectAttempts - 1);
      baseDelayMs = min(exponential.toInt(), config.maxAggressiveDelay.inMilliseconds);
    } else {
      baseDelayMs = config.coverInterval.inMilliseconds;
    }

    final jitter = baseDelayMs * config.jitterFactor * (2 * _random.nextDouble() - 1);
    final finalDelayMs = max(100, (baseDelayMs + jitter).round());
    final finalDelay = Duration(milliseconds: finalDelayMs);

    final phase = _reconnectAttempts <= config.aggressiveAttempts ? 'aggressive' : 'cover';
    _log('Reconnecting in ${finalDelay.inMilliseconds}ms (attempt $_reconnectAttempts, $phase)');

    Future.delayed(finalDelay, () {
      _isReconnecting = false;
      _smartReconnect();
    });
  }

  // ---------------------------------------------------------------------------
  // Presence handling
  // ---------------------------------------------------------------------------

  void _handlePresence(tinode.PresMessage pres) {
    if (pres.src == null) return;

    final what = pres.what;
    if (what == 'on' || what == 'off') {
      final isOnline = what == 'on';
      final tinodeUserId = pres.src!;

      // Reverse lookup to app user ID
      identityResolver.reverseLookup(tinodeUserId).then((appUserId) {
        final userId = appUserId ?? tinodeUserId;
        _presenceMap[userId] = isOnline;
        onPresenceChanged?.call(userId, isOnline);
      });
    }
  }

  void _handleSubsUpdated(List<tinode.TopicSubscription> subs) {
    // Seed identity resolver from subscription metadata
    for (final sub in subs) {
      if (sub.user != null && sub.public != null && sub.public is Map) {
        final appUserId = (sub.public as Map)['appUserId'];
        if (appUserId != null && appUserId is String) {
          identityResolver.addMapping(appUserId, sub.user!);
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<List<tictac_models.Topic>> _buildTopicList(tinode.TopicMe me) async {
    final topics = <tictac_models.Topic>[];

    for (final sub in me.contacts) {
      if (sub.topic == null) continue;

      // Skip system topics
      final topicName = sub.topic!;
      if (topicName == 'me' || topicName == 'fnd' || topicName == 'sys') continue;

      final isP2P = tinode.Tools.isP2PTopicName(topicName);
      final isGroup = tinode.Tools.isGroupTopicName(topicName);
      if (!isP2P && !isGroup) continue;

      // Resolve name
      String? displayName;
      if (sub.public != null && sub.public is Map) {
        displayName = (sub.public as Map)['fn'];
      }

      // Build last message preview if available
      MessagePreview? lastMessage;
      // seq indicates messages exist but we don't have content from the sub

      // Resolve member IDs for P2P
      final memberIds = <String>[];
      memberIds.add(config.appUserId);
      if (isP2P) {
        final otherAppUserId = await identityResolver.reverseLookup(topicName);
        if (otherAppUserId != null) {
          memberIds.add(otherAppUserId);
          displayName ??= otherAppUserId;
        } else {
          memberIds.add(topicName);
          displayName ??= topicName;
        }
      }

      topics.add(tictac_models.Topic(
        id: topicName,
        name: displayName,
        type: isP2P ? TopicType.direct : TopicType.group,
        memberAppUserIds: memberIds,
        lastMessage: lastMessage,
        memberCount: isP2P ? 2 : (sub.seq ?? 0),
      ));
    }

    return topics;
  }

  void _log(String message) {
    // ignore: avoid_print
    print('TicTac: $message');
  }
}
