import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:rxdart/rxdart.dart';
import 'package:tictac/tinode.dart' as tinode;
import 'package:tictac/src/models/rest-auth-secret.dart';
import 'package:tictac/src/tictac/tictac_config.dart';
import 'package:tictac/src/tictac/connection_state.dart';
import 'package:tictac/src/tictac/models/topic.dart' as tictac_models;
import 'package:tictac/src/tictac/models/topic_type.dart';
import 'package:tictac/src/tictac/models/message_preview.dart';
import 'package:tictac/src/tictac/identity/identity_resolver.dart';
import 'package:tictac/src/tictac/identity/cached_identity_resolver.dart';
import 'package:tictac/src/tictac/identity/tags_identity_resolver.dart';
import 'package:tictac/src/tictac/topic_controller.dart';

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
  final Map<String, TopicController> _topicControllers = {};
  final Map<String, String> _topicNames = {}; // topicId -> display name
  late IdentityResolver identityResolver;

  // Connection state
  final BehaviorSubject<TicTacConnectionState> _connectionState =
      BehaviorSubject.seeded(TicTacConnectionState.disconnected);
  Stream<TicTacConnectionState> get connectionState => _connectionState.stream;
  TicTacConnectionState get currentConnectionState => _connectionState.value;

  // Heartbeat
  Timer? _heartbeatTimer;
  Timer? _pongTimer;
  bool _awaitingPong = false;
  StreamSubscription? _onNetworkProbeSub;

  // App lifecycle
  DateTime? _backgroundedAt;

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
    if (identityResolver != null) {
      this.identityResolver = identityResolver;
    } else if (config.tagsBaseUrl != null && config.tagsBaseUrl!.isNotEmpty) {
      this.identityResolver = TagsIdentityResolver(
        tagsBaseUrl: config.tagsBaseUrl!,
        appId: config.appId,
        appKey: config.appKey,
      );
    } else {
      this.identityResolver = CachedIdentityResolver();
    }
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
    _connectionState.add(TicTacConnectionState.connecting);

    try {
      // Build upgrade headers with app credentials and optional auth token
      final upgradeHeaders = <String, String>{
        'x-app-id': config.appId,
        'x-app-key': config.appKey,
      };
      final token = await config.authTokenProvider();
      if (token != null && token.isNotEmpty) {
        upgradeHeaders['authorization'] = 'Bearer $token';
      }

      _tinode = tinode.Tinode(
        'TicTac/1.0',
        tinode.ConnectionOptions(
          config.wsHostPort,
          config.apiKey,
          secure: config.secure,
          headers: upgradeHeaders,
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

      // Wait for subscription data to arrive from server
      final subsReady = Completer<void>();
      late StreamSubscription subsSub;
      subsSub = me.onSubsUpdated.listen((_) {
        if (!subsReady.isCompleted) subsReady.complete();
        subsSub.cancel();
      });

      await me.subscribe(
        tinode.MetaGetBuilder(me).withLaterSub(null).build(),
        null,
      );

      // Wait for subs data or timeout (new users may have no contacts)
      await subsReady.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          subsSub.cancel();
        },
      );

      // Build topic list from fresh server data
      final topics = await _buildTopicList(me);

      // Reset reconnect state on success
      _reconnectAttempts = 0;
      _isReconnecting = false;
      _firstFailureTime = null;

      _connectionState.add(TicTacConnectionState.connected);
      _startHeartbeat();

      onConnected?.call(topics);
      return topics;
    } catch (e) {
      _log('Connection failed: $e');
      _connectionState.add(TicTacConnectionState.disconnected);
      onDisconnected?.call('Connection failed: $e');
      _scheduleReconnect();
      rethrow;
    }
  }

  /// Disconnect from Tinode.
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _stopHeartbeat();
    _onDisconnectSub?.cancel();
    _onPressSub?.cancel();
    _onSubsUpdatedSub?.cancel();
    _onNetworkProbeSub?.cancel();
    _tinode?.disconnect();
    _tinode = null;
    _presenceMap.clear();
    _topicNames.clear();
    _connectionState.add(TicTacConnectionState.disconnected);
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
    _connectionState.close();
  }

  // ---------------------------------------------------------------------------
  // Heartbeat
  // ---------------------------------------------------------------------------

  void _startHeartbeat() {
    _stopHeartbeat();
    _awaitingPong = false;

    // Subscribe to pong responses
    _onNetworkProbeSub?.cancel();
    _onNetworkProbeSub = _tinode?.onNetworkProbe.listen((_) {
      _awaitingPong = false;
      _pongTimer?.cancel();
    });

    _heartbeatTimer = Timer.periodic(config.heartbeatInterval, (_) {
      _sendHeartbeat();
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _pongTimer?.cancel();
    _pongTimer = null;
    _awaitingPong = false;
  }

  void _sendHeartbeat() {
    if (_tinode == null || !_tinode!.isConnected) {
      _declareDead('Socket not connected');
      return;
    }

    if (_awaitingPong) {
      _declareDead('Previous pong never arrived');
      return;
    }

    try {
      _tinode!.networkProbe();
      _awaitingPong = true;
      _pongTimer = Timer(config.pongTimeout, () {
        _declareDead('Pong timeout');
      });
    } catch (e) {
      _declareDead('Probe send failed: $e');
    }
  }

  void _declareDead(String reason) {
    _stopHeartbeat();
    _log('Heartbeat: $reason — declaring connection dead');
    onDisconnected?.call('Heartbeat timeout');
    _scheduleReconnect();
  }

  // ---------------------------------------------------------------------------
  // App lifecycle
  // ---------------------------------------------------------------------------

  /// Call this from the consuming app when app lifecycle state changes.
  /// Enables automatic reconnection after backgrounding.
  void handleAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _onAppBackgrounded();
    } else if (state == AppLifecycleState.resumed) {
      _onAppResumed();
    }
  }

  void _onAppBackgrounded() {
    _backgroundedAt = DateTime.now();
    _stopHeartbeat();
  }

  void _onAppResumed() {
    final wasBg = _backgroundedAt;
    _backgroundedAt = null;

    if (_intentionalDisconnect) return;

    if (wasBg != null &&
        DateTime.now().difference(wasBg) > config.backgroundReconnectThreshold) {
      _log('Resumed after long background — forcing reconnect');
      _smartReconnect();
      return;
    }

    // Quick health check then resume heartbeat
    if (_tinode == null || !_tinode!.isConnected) {
      _log('Resumed but socket is dead — reconnecting');
      _smartReconnect();
    } else {
      _startHeartbeat();
    }
  }

  // ---------------------------------------------------------------------------
  // Pre-operation health check
  // ---------------------------------------------------------------------------

  Future<void> _ensureConnected() async {
    if (_tinode != null && _tinode!.isConnected) return;

    final state = _connectionState.value;
    if (state == TicTacConnectionState.connecting ||
        state == TicTacConnectionState.reconnecting) {
      _log('Waiting for connection to establish...');
      await _connectionState.stream
          .firstWhere((s) => s == TicTacConnectionState.connected)
          .timeout(const Duration(seconds: 15));
      return;
    }

    _log('Pre-operation health check failed — reconnecting');
    final future = _connectionState.stream
        .firstWhere((s) => s == TicTacConnectionState.connected)
        .timeout(const Duration(seconds: 15));
    _smartReconnect();
    await future;
  }

  // ---------------------------------------------------------------------------
  // TopicController re-attachment after reconnect
  // ---------------------------------------------------------------------------

  Future<void> _reattachTopicControllers() async {
    final entries = Map.of(_topicControllers);
    for (final entry in entries.entries) {
      final topicId = entry.key;
      final controller = entry.value;

      try {
        final topic = _tinode!.getTopic(topicId);

        if (!topic.isSubscribed) {
          tinode.MetaGetBuilder builder;
          try {
            builder = tinode.MetaGetBuilder(topic)
                .withLaterData(config.recentMessages)
                .withLaterSub(null);
          } on Error {
            builder = tinode.MetaGetBuilder(topic)
                .withData(null, null, config.recentMessages)
                .withSub(null, null, null);
          }
          await topic.subscribe(builder.build(), null);
        }

        controller.attachToTopic(topic);
        controller.setConnected(true);
        _log('Reattached topic $topicId');
      } catch (e) {
        _log('Failed to reattach topic $topicId: $e');
        controller.setConnected(false);
      }
    }
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

  /// Get the current list of topics from the server.
  /// Always fetches fresh data — never reads from cache.
  Future<List<tictac_models.Topic>> getTopics() async {
    await _ensureConnected();

    final me = _tinode!.getMeTopic();

    // Clear stale contacts before fetching fresh data
    me.clearContacts();

    // Wait for fresh subscription data from the server
    final completer = Completer<void>();
    late StreamSubscription sub;
    sub = me.onSubsUpdated.listen((_) {
      if (!completer.isCompleted) completer.complete();
      sub.cancel();
    });

    // Request fresh subscriptions
    _tinode!.getMeta(
      'me',
      tinode.GetQuery.fromMessage({'what': 'sub'}),
    );

    // Wait for response or timeout
    await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        sub.cancel();
      },
    );

    return _buildTopicList(me);
  }

  /// Create a group topic with the given name and members.
  Future<tictac_models.Topic> createGroupTopic(
    String name,
    List<String> memberAppUserIds,
  ) async {
    await _ensureConnected();

    // Resolve app user IDs to tinode user IDs for invites
    final tinodeUserIds = <String>[];
    for (final appUserId in memberAppUserIds) {
      final tinodeId = await identityResolver.lookup(appUserId);
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

    final topicId = newTopic.name!;
    _topicNames[topicId] = name;

    return tictac_models.Topic(
      id: topicId,
      name: name,
      type: TopicType.group,
      memberAppUserIds: [config.appUserId, ...memberAppUserIds],
    );
  }

  /// Create a direct (P2P) topic with another user.
  Future<tictac_models.Topic> createDirectTopic(String otherAppUserId) async {
    await _ensureConnected();

    final otherTinodeId = await identityResolver.lookup(otherAppUserId);
    if (otherTinodeId == null) {
      throw Exception('Cannot resolve user ID: $otherAppUserId');
    }

    final p2pTopic = _tinode!.newTopicWith(otherTinodeId);
    await p2pTopic.subscribe(
      tinode.MetaGetBuilder(p2pTopic).build(),
      null,
    );

    final topicId = p2pTopic.name!;
    _topicNames[topicId] = otherAppUserId;

    return tictac_models.Topic(
      id: topicId,
      name: otherAppUserId,
      type: TopicType.direct,
      memberAppUserIds: [config.appUserId, otherAppUserId],
    );
  }

  /// Join a topic and return a TopicController for interacting with it.
  Future<TopicController> joinTopic(String topicId) async {
    await _ensureConnected();

    // Return existing controller if already joined
    if (_topicControllers.containsKey(topicId)) {
      return _topicControllers[topicId]!;
    }

    final topic = _tinode!.getTopic(topicId);

    if (!topic.isSubscribed) {
      // Use withLaterSub for previously-subscribed topics (has cached desc),
      // fall back to withSub for new topics where _lastDescUpdate is uninitialized
      tinode.MetaGetBuilder builder;
      try {
        builder = tinode.MetaGetBuilder(topic)
            .withLaterData(config.recentMessages)
            .withLaterSub(null);
      } on Error {
        builder = tinode.MetaGetBuilder(topic)
            .withData(null, null, config.recentMessages)
            .withSub(null, null, null);
      }
      await topic.subscribe(builder.build(), null);
    }

    final controller = TopicController(
      topicId: topicId,
      userId: config.appUserId,
      identityResolver: identityResolver,
    );
    controller.attachToTopic(topic);
    _topicControllers[topicId] = controller;
    return controller;
  }

  /// Delete a topic.
  Future<void> deleteTopic(String topicId, {bool hard = false}) async {
    await _ensureConnected();
    await _tinode!.deleteTopic(topicId, hard);
    final controller = _topicControllers.remove(topicId);
    controller?.dispose();
  }

  /// Leave a topic (detach without deleting).
  Future<void> leaveTopic(String topicId) async {
    await _ensureConnected();
    await _tinode!.leave(topicId, false);
    final controller = _topicControllers.remove(topicId);
    controller?.dispose();
  }

  // ---------------------------------------------------------------------------
  // Reconnection (two-phase with wall-clock limit)
  // ---------------------------------------------------------------------------

  Future<void> _smartReconnect() async {
    _intentionalDisconnect = false;
    _stopHeartbeat();
    _connectionState.add(TicTacConnectionState.reconnecting);

    // Notify all controllers they're disconnected
    for (final controller in _topicControllers.values) {
      controller.setConnected(false);
    }

    try {
      // Clean up old connection
      _onDisconnectSub?.cancel();
      _onPressSub?.cancel();
      _onSubsUpdatedSub?.cancel();
      _onNetworkProbeSub?.cancel();
      _tinode?.disconnect();
      _tinode = null;

      await connect();
      await _reattachTopicControllers();
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
      _connectionState.add(TicTacConnectionState.failed);
      onDisconnected?.call(
        'Chat unavailable — could not reconnect after ${config.maxReconnectDuration.inMinutes} minutes',
      );
      return;
    }

    _isReconnecting = true;
    _reconnectAttempts++;
    _connectionState.add(TicTacConnectionState.reconnecting);

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
      }).catchError((e) {
        _log('Presence reverseLookup error: $e');
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

      // Resolve display name:
      // 1. Check local name map (set during createGroupTopic/createDirectTopic)
      // 2. Check subscription's public field (user's display name for P2P)
      // 3. For group topics, fetch topic description from server
      String? displayName = _topicNames[topicName];
      if (displayName == null && sub.public != null && sub.public is Map) {
        displayName = (sub.public as Map)['fn'];
      }
      if (displayName == null && isGroup) {
        // Fetch topic description from server for the group name
        try {
          final topic = _tinode!.getTopic(topicName);
          // Check if the topic already has cached desc
          if (topic.public != null && topic.public is Map) {
            displayName = (topic.public as Map)['fn'];
          }
          // If not, subscribe briefly to get the desc
          if (displayName == null) {
            await topic.subscribe(
              tinode.MetaGetBuilder(topic).withDesc(null).build(),
              null,
            );
            if (topic.public != null && topic.public is Map) {
              displayName = (topic.public as Map)['fn'];
            }
            await topic.leave(false);
          }
        } catch (_) {}
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
