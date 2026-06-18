import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:rxdart/rxdart.dart';
import 'package:tictac/tinode.dart' as tinode;
import 'package:tictac/src/models/access-mode.dart' as access_mode;
import 'package:tictac/src/models/rest-auth-secret.dart';
import 'package:tictac/src/tictac/tictac_callbacks.dart';
import 'package:tictac/src/tictac/tictac_config.dart';
import 'package:tictac/src/tictac/connection_state.dart';
import 'package:tictac/src/tictac/models/topic.dart' as tictac_models;
import 'package:tictac/src/tictac/models/topic_type.dart';
import 'package:tictac/src/tictac/peer_read_state.dart';
import 'package:tictac/src/tictac/topic_handle.dart';
import 'package:tictac/src/tictac/voice/voice_callbacks.dart';
import 'package:tictac/src/tictac/voice/voice_module.dart';
import 'package:tictac/src/tictac/voice/voice_session.dart';

/// Default Tinode access mode for a plain group member:
/// Join, Read, Write, Presence, Share.
///
/// The Share (`S`) bit is what lets Tinode broadcast `{pres what=acs}`
/// roster changes to this user — without it, `notifySubChange` on the
/// server filters by `filterIn: ModeCSharer` and only admins/owners
/// learn that a member joined or was ejected. For Bonkers' flat
/// friend-group model (no admin tier in the UI), every member is
/// effectively an equal participant, so granting Sharer matches the
/// product intent and makes mid-life onMemberAdded / onMemberRemoved
/// reach every peer instead of only owners.
///
/// Side effect: every group member can invite / eject others. This is
/// the intended UX for friend groups; revisit if a product surface
/// introduces an explicit owner/admin/member hierarchy.
const String _kDefaultMemberMode = 'JRWPS';

/// Tinode "eject" pattern: there is no dedicated eject API on
/// [tinode.Topic]. Setting access mode to None (`'N'`) removes the user
/// from the topic and triggers the server-side `{pres what=acs}` that
/// fires [TicTacCallbacks.onMemberRemoved] on every other subscriber.
const String _kEjectMode = 'N';

/// Entry point for TicTac.
///
/// Stateless on the chat side: every event surfaces through
/// [TicTacCallbacks]. The module owns the Tinode socket and routes
/// events; it does NOT remember messages, members, presence, or typing
/// state. The caller (or `TicTacChat`) maintains whatever it wants to
/// display.
///
/// The one piece of state the module does keep is the set of currently-
/// subscribed topic ids — needed to compute add/remove deltas against
/// Tinode's "here is the full sub list" event. Nothing else.
class TicTacModule {
  final TicTacConfig config;

  // Multi-listener fan-out: every event iterates the live list and
  // invokes the relevant callback on each registered bag. Callers add /
  // remove their bag at the right lifecycle moment. The first one is
  // an optional bag the module's constructor takes for convenience —
  // typical app code passes its "host" callbacks here and lets
  // `TicTacChat` (or any other widget) `addCallbacks` for its own use.
  final List<TicTacCallbacks> _listeners = [];

  /// Register an additional callbacks bag. Returns the same bag for
  /// chaining. Idempotent — adding the same instance twice is a no-op.
  TicTacCallbacks addCallbacks(TicTacCallbacks callbacks) {
    if (!_listeners.contains(callbacks)) _listeners.add(callbacks);
    return callbacks;
  }

  /// Remove a previously-added callbacks bag. No-op if the bag was
  /// never registered.
  void removeCallbacks(TicTacCallbacks callbacks) {
    _listeners.remove(callbacks);
  }

  void _fire(void Function(TicTacCallbacks c) f) {
    // Copy to a local so a listener that triggers add/remove during a
    // fire doesn't mutate the iterator we're walking.
    for (final c in List<TicTacCallbacks>.of(_listeners)) {
      f(c);
    }
  }

  // ---------------------------------------------------------------------------
  // Internal state — kept small; nothing here is exposed to callers.
  // ---------------------------------------------------------------------------

  tinode.Tinode? _tinode;
  tinode.AuthToken? _cachedToken;
  bool _intentionalDisconnect = false;
  bool _isReconnecting = false;
  int _reconnectAttempts = 0;
  DateTime? _firstFailureTime;
  final _random = Random();

  // Coalesce concurrent connect() calls. Multiple paths can race the
  // first connect (host bridge calling connect() at app start AND the
  // lifecycle observer firing _onAppResumed → _smartReconnect →
  // connect() before the first one completes). Without this guard, both
  // callers reassign _tinode and its stream subscriptions; the
  // heartbeat ends up listening on one Tinode while probing another and
  // never declares-dead. The actual symptom: ~50s of silence after a
  // dropped socket before the SDK itself eventually times out.
  Future<void>? _connecting;

  // Diff source: previous topic-id set, used to fire add/remove/update
  // when Tinode dumps the full sub list.
  final Set<String> _knownTopicIds = {};

  // Per-joined-topic subscriptions. Owns the StreamSubscriptions opened
  // against tinode.Topic streams; tearing this down on leave() detaches
  // event delivery for that topic.
  final Map<String, _ActiveTopic> _activeTopics = {};

  VoiceModule? _voiceFactory;

  // Connection state (still a Stream for backwards-compatible inspection
  // from inside the module; not part of the public API).
  final BehaviorSubject<TicTacConnectionState> _connectionState =
      BehaviorSubject.seeded(TicTacConnectionState.disconnected);
  TicTacConnectionState get currentConnectionState => _connectionState.value;

  // Device token for push notifications. Stored here so we can re-send
  // it on every (re)connect — Tinode's `{hi}` packet carries the
  // device token, and a fresh socket starts over without it. Empty
  // string clears upstream; null means "host never set one yet."
  String? _pendingDeviceToken;

  // Heartbeat
  Timer? _heartbeatTimer;
  Timer? _pongTimer;
  bool _awaitingPong = false;
  StreamSubscription? _onNetworkProbeSub;

  // BNK-581 inbound watchdog. Tinode's session idle reaper only resets
  // its read deadline on WebSocket-protocol Pongs (server/hdl_websock.go
  // SetPongHandler). Application messages — including tictac's '1'/'0'
  // probe — don't update lastAction's reaping field. So when the WS
  // control frames get stripped somewhere upstream (ALB suspected in
  // dev), the session is reaped at ~55s and the socket sits silent.
  // The watchdog tracks the last server byte we saw; if we go quieter
  // than [TicTacConfig.inboundIdleThreshold], something is wrong and
  // a reconnect is the safe move regardless of root cause.
  DateTime? _lastInboundAt;
  StreamSubscription? _onRawMessageSub;

  // BNK-581 app-level keepalive. The '1'/'0' probe is fine for fast
  // client-side dead detection, but its reply doesn't count as
  // session activity server-side. Sending a real protocol message
  // (me.getMeta(withDesc)) every [appKeepaliveInterval] generates an
  // inbound {meta} reply that keeps the watchdog calm AND validates
  // the session is actually serving requests — if the reply doesn't
  // arrive within the SDK's future timeout, we know the session is
  // dead even before the watchdog window closes.
  Timer? _appKeepaliveTimer;

  // App lifecycle
  DateTime? _backgroundedAt;

  StreamSubscription? _onDisconnectSub;
  StreamSubscription? _onPressSub;
  StreamSubscription? _onSubsUpdatedSub;
  StreamSubscription? _onContactUpdateSub;

  // Topics for which a transient "fetch the latest message" is in flight, so a
  // burst of `msg` presence events for the same topic doesn't stack subscribes.
  final Set<String> _fetchingTopics = {};

  TicTacModule(this.config, [TicTacCallbacks? initialCallbacks]) {
    if (initialCallbacks != null) _listeners.add(initialCallbacks);
  }

  bool get isConnected => _tinode?.isConnected ?? false;

  /// The connected user's Tinode user id (e.g. "usrAbc123"), or null if not
  /// connected/authenticated. Exposed so callers and tests can form P2P
  /// topics directly (createDirectTopic takes a tinode uid) without a TAGS
  /// resolve roundtrip.
  String? get tinodeUserId {
    final t = _tinode;
    if (t == null || !t.isConnected) return null;
    try {
      return t.userId;
    } catch (_) {
      return null; // not yet authenticated
    }
  }

  /// Returns a copy of the current user's `me.public` map, or null if not
  /// connected. Read-only — the provisioner Lambda writes `appUserId`
  /// into this during account creation.
  Map<String, dynamic>? getSelfPublic() {
    final me = _tinode?.getMeTopic();
    final pub = me?.public;
    if (pub is Map) return Map<String, dynamic>.from(pub);
    return null;
  }

  // ---------------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------------

  /// Connect, authenticate, and fire `onConnected(topics)`. Idempotent
  /// reconnects re-fire `onConnected` with a fresh topic list.
  Future<void> connect() {
    final inflight = _connecting;
    if (inflight != null) return inflight;
    final future = _doConnect();
    _connecting = future;
    return future.whenComplete(() {
      if (identical(_connecting, future)) _connecting = null;
    });
  }

  Future<void> _doConnect() async {
    _intentionalDisconnect = false;
    _connectionState.add(TicTacConnectionState.connecting);

    try {
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

      _onDisconnectSub?.cancel();
      _onDisconnectSub = _tinode!.onDisconnect.listen((_) {
        if (_intentionalDisconnect) return;
        _log('Disconnected unexpectedly');
        _fire((c) => c.onDisconnected?.call('Connection lost'));
        _scheduleReconnect();
      });

      await _tinode!.connect().timeout(
        config.connectTimeout,
        onTimeout: () {
          // Force the SDK socket closed so subsequent reconnect attempts
          // don't reuse a half-open Tinode instance.
          _tinode?.disconnect();
          throw TimeoutException(
            'Tinode connect did not complete within ${config.connectTimeout.inSeconds}s',
          );
        },
      );
      _log('Connected to ${config.wsHostPort}');

      await _authenticate();
      _log('Authenticated as ${_tinode!.userId}');

      // Replay any device token set before connection (or carried across
      // a reconnect). Failing here doesn't block the rest of the
      // bring-up; pushes just won't fire for this session, and the host
      // will retry on next onTokenRefresh / app launch.
      if (_pendingDeviceToken != null) {
        try {
          await _tinode!.setDeviceToken(_pendingDeviceToken!);
          _log('Device token re-applied on connect');
        } catch (e) {
          _log('setDeviceToken on connect failed: $e');
        }
      }

      final me = _tinode!.getMeTopic();

      _onPressSub?.cancel();
      _onPressSub = me.onPres.listen(_handleMePresence);

      _onSubsUpdatedSub?.cancel();
      _onSubsUpdatedSub = me.onSubsUpdated.listen(_handleSubsUpdated);

      // New messages on topics we haven't joined arrive as `msg` presence on
      // `me` (seq bump only, no content). Fetch the body and surface it via
      // onMessageReceived so the app sees activity on every topic, not just
      // joined ones.
      _onContactUpdateSub?.cancel();
      _onContactUpdateSub = me.onContactUpdate.listen(_handleContactUpdate);

      // Wait for subscription data to arrive from server.
      final subsReady = Completer<void>();
      late StreamSubscription subsSub;
      subsSub = me.onSubsUpdated.listen((_) {
        if (!subsReady.isCompleted) subsReady.complete();
        subsSub.cancel();
      });

      await me.subscribe(
        tinode.MetaGetBuilder(me).withDesc(null).withLaterSub(null).build(),
        null,
      );

      await subsReady.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => subsSub.cancel(),
      );

      final topics = await _buildTopicList(me);
      _knownTopicIds
        ..clear()
        ..addAll(topics.map((t) => t.id));

      // Reset reconnect state on success.
      _reconnectAttempts = 0;
      _isReconnecting = false;
      _firstFailureTime = null;

      _connectionState.add(TicTacConnectionState.connected);
      _startHeartbeat();

      // Re-subscribe any topics that were active before a reconnect.
      // This MUST happen before firing onConnected — callers commonly
      // re-join their active topic immediately on receiving the event
      // and would otherwise get a stale handle whose underlying tinode
      // Topic still belongs to the previous (now disposed) socket.
      // No-op on the first connect when _activeTopics is empty.
      await _reattachActiveTopics();

      _fire((c) => c.onConnected?.call(topics));

      // Replay each topic's last text + last custom message so the app caches
      // messages that predate this session (offline catch-up; chats others
      // started). Fire-and-forget so it doesn't delay connect.
      unawaited(_warmAllTopics(topics));
    } catch (e) {
      _log('Connection failed: $e');
      _connectionState.add(TicTacConnectionState.disconnected);
      _fire((c) => c.onDisconnected?.call('Connection failed: $e'));
      _scheduleReconnect();
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _stopHeartbeat();
    _onDisconnectSub?.cancel();
    _onPressSub?.cancel();
    _onSubsUpdatedSub?.cancel();
    _onContactUpdateSub?.cancel();
    _onNetworkProbeSub?.cancel();
    for (final t in _activeTopics.values) {
      await t.dispose();
    }
    _activeTopics.clear();
    _knownTopicIds.clear();
    _tinode?.disconnect();
    _tinode = null;
    _connectionState.add(TicTacConnectionState.disconnected);
  }

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
  // Device token (push notifications)
  // ---------------------------------------------------------------------------

  /// Register a push notification device token with Tinode.
  ///
  /// The token is sent in Tinode's `{hi}` packet and identifies this
  /// device to whatever push adapter Tinode is configured with (FCM,
  /// tnpg, etc.). Stored and re-sent on every (re)connect — a fresh
  /// socket starts a new session without the token, so the host doesn't
  /// have to track connection state to keep push registration alive.
  ///
  /// Pass `null` or an empty string to clear the token upstream (e.g.
  /// on logout). Calling this before [connect] just stores the token;
  /// it'll be applied as part of the next connect.
  Future<void> setDeviceToken(String? token) async {
    final normalized = (token == null || token.isEmpty) ? '' : token;
    _pendingDeviceToken = normalized;
    if (_tinode != null && _tinode!.isConnected) {
      try {
        await _tinode!.setDeviceToken(normalized);
      } catch (e) {
        _log('setDeviceToken live update failed: $e');
        rethrow;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Topic operations
  // ---------------------------------------------------------------------------

  /// Force-refresh the topic list from the server. Fires
  /// `onTopicAdded` / `onTopicRemoved` / `onTopicUpdated` as deltas
  /// against the previously-seen set.
  Future<List<tictac_models.Topic>> refreshTopics() async {
    await _ensureConnected();
    final me = _tinode!.getMeTopic();
    me.clearContacts();

    final completer = Completer<void>();
    late StreamSubscription sub;
    sub = me.onSubsUpdated.listen((_) {
      if (!completer.isCompleted) completer.complete();
      sub.cancel();
    });

    _tinode!.getMeta('me', tinode.GetQuery.fromMessage({'what': 'sub'}));

    await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => sub.cancel(),
    );
    return _buildTopicList(me);
  }

  /// Create a group topic with the given display name + initial members.
  ///
  /// Bulk-resolves [memberAppUserIds] to Tinode user ids via
  /// [TicTacConfig.resolveTinodeUserIds]. Members that fail to resolve
  /// are dropped with a log line — the group is created with whoever
  /// could be resolved. Throws [StateError] if members are passed but
  /// no bulk resolver is configured. An empty member list is allowed
  /// without a resolver (owner-only group / test setup).
  Future<tictac_models.Topic> createGroupTopic(
    String name,
    List<String> memberAppUserIds,
  ) async {
    await _ensureConnected();
    final resolver = config.resolveTinodeUserIds;
    if (memberAppUserIds.isNotEmpty && resolver == null) {
      throw StateError(
          'createGroupTopic with members requires '
          'TicTacConfig.resolveTinodeUserIds');
    }
    final mappings = memberAppUserIds.isEmpty
        ? const <String, String>{}
        : await resolver!(memberAppUserIds);
    final resolved = <String>[];     // appUserIds that mapped successfully
    final tinodeIds = <String>[];    // tinodeUserIds, parallel to resolved
    for (final appUserId in memberAppUserIds) {
      final tinodeUid = mappings[appUserId];
      if (tinodeUid == null) {
        _log('createGroupTopic: dropping member $appUserId — no tinode '
            'mapping');
        continue;
      }
      resolved.add(appUserId);
      tinodeIds.add(tinodeUid);
    }

    final newTopic = _tinode!.newTopic();
    final setParams = tinode.SetParams()
      ..desc = (tinode.TopicDescription()..public = {'fn': name});
    await newTopic.subscribe(
      tinode.MetaGetBuilder(newTopic).build(),
      setParams,
    );
    for (final tinodeUid in tinodeIds) {
      try {
        await newTopic.invite(tinodeUid, _kDefaultMemberMode);
      } catch (e) {
        _log('createGroupTopic: invite $tinodeUid failed: $e');
      }
    }
    return tictac_models.Topic(
      id: newTopic.name!,
      name: name,
      type: TopicType.group,
      memberAppUserIds: resolved,
    );
  }

  /// Create a direct (P2P) topic with another user by tinode user id.
  /// Returns the new topic; the caller can `joinTopic` it for events.
  Future<tictac_models.Topic> createDirectTopic(
      String otherTinodeUserId) async {
    await _ensureConnected();
    final p2pTopic = _tinode!.newTopicWith(otherTinodeUserId);
    await p2pTopic.subscribe(
      tinode.MetaGetBuilder(p2pTopic).build(),
      null,
    );
    final otherAppUserId =
        await config.resolveAppUserId(otherTinodeUserId);
    return tictac_models.Topic(
      id: p2pTopic.name!,
      name: otherAppUserId ?? otherTinodeUserId,
      type: TopicType.direct,
      memberAppUserIds:
          otherAppUserId != null ? [otherAppUserId] : const [],
    );
  }

  /// Join a topic. Wires up event listeners and emits cached messages,
  /// members, and presence through the callback bag. Returns a
  /// methods-only handle for sending / leaving / etc.
  ///
  /// Re-joining a still-active topic is a cache hit: returns the same
  /// handle and replays the SDK's locally-cached messages through
  /// onMessageReceived so a re-mounted UI populates without hitting the
  /// network.
  Future<TopicHandle> joinTopic(String topicId) async {
    await _ensureConnected();
    final existing = _activeTopics[topicId];
    if (existing != null) {
      // Defer to the next microtask so the caller has a chance to
      // register its callbacks (most callers do addCallbacks → joinTopic
      // back to back) before we start firing onMessageReceived.
      scheduleMicrotask(() => existing.replayCachedMessages());
      return existing.handle;
    }

    final topic = _tinode!.getTopic(topicId);
    final isGroup = tinode.Tools.isGroupTopicName(topicId);
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
    // BNK-594: groups also need desc.public (name + photo) on the
    // first join. Without this the chat-screen header reads
    // topic.public as null and falls back to member-names until
    // something else triggers a meta-desc fetch.
    if (isGroup) {
      builder.withDesc(null);
    }
    if (!topic.isSubscribed) {
      await topic.subscribe(builder.build(), null);
    } else {
      // Topic was subscribed elsewhere (e.g. createDirectTopic on bootup)
      // without a data fetch, so the local cache is empty. Pull history
      // now — otherwise the first joinTopic for this id hands back an
      // empty chat even though the server has messages.
      await topic.getMeta(builder.build());
    }

    final active = _ActiveTopic(
      topicId: topicId,
      topic: topic,
      module: this,
    );
    active.attach();
    _activeTopics[topicId] = active;
    return active.handle;
  }

  Future<void> deleteTopic(String topicId, {bool hard = false}) async {
    await _ensureConnected();
    await _tinode!.deleteTopic(topicId, hard);
    final active = _activeTopics.remove(topicId);
    await active?.dispose();
  }

  // ---------------------------------------------------------------------------
  // Voice
  // ---------------------------------------------------------------------------

  /// Mint a LiveKit JWT for [topicId] and join the corresponding voice
  /// room. The returned session fires events via [voiceCallbacks].
  Future<VoiceSession> joinVoice(
    String topicId, {
    required VoiceCallbacks voiceCallbacks,
  }) async {
    await _ensureConnected();
    _voiceFactory ??= VoiceModule(config: config);
    return _voiceFactory!.joinVoice(topicId, voiceCallbacks);
  }

  // ---------------------------------------------------------------------------
  // App lifecycle (caller routes Flutter app lifecycle here)
  // ---------------------------------------------------------------------------

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
    // A connect is already in flight (most commonly: the host called
    // connect() at app boot, then Flutter fired resumed during the same
    // first frame). Don't trampoline — let the in-flight attempt finish.
    if (_connecting != null) return;
    if (wasBg != null &&
        DateTime.now().difference(wasBg) >
            config.backgroundReconnectThreshold) {
      _log('Resumed after long background — forcing reconnect');
      _smartReconnect();
      return;
    }
    if (_tinode == null || !_tinode!.isConnected) {
      _log('Resumed but socket is dead — reconnecting');
      _smartReconnect();
    } else {
      _startHeartbeat();
    }
  }

  // ---------------------------------------------------------------------------
  // Heartbeat
  // ---------------------------------------------------------------------------

  void _startHeartbeat() {
    _stopHeartbeat();
    _awaitingPong = false;
    _lastInboundAt = DateTime.now();
    _onNetworkProbeSub?.cancel();
    _onNetworkProbeSub = _tinode?.onNetworkProbe.listen((_) {
      _awaitingPong = false;
      _pongTimer?.cancel();
      _log('Heartbeat: pong received');
    });
    // BNK-581: every inbound frame (probe reply, ctrl, meta, data, pres,
    // info) shows the socket is delivering something. Watchdog reads
    // this timestamp on its periodic tick.
    _onRawMessageSub?.cancel();
    _onRawMessageSub = _tinode?.onRawMessage.listen((_) {
      _lastInboundAt = DateTime.now();
    });
    _heartbeatTimer =
        Timer.periodic(config.heartbeatInterval, (_) => _sendHeartbeat());
    _appKeepaliveTimer?.cancel();
    _appKeepaliveTimer =
        Timer.periodic(config.appKeepaliveInterval, (_) => _sendAppKeepalive());
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _pongTimer?.cancel();
    _pongTimer = null;
    _awaitingPong = false;
    _appKeepaliveTimer?.cancel();
    _appKeepaliveTimer = null;
    _onRawMessageSub?.cancel();
    _onRawMessageSub = null;
    _lastInboundAt = null;
  }

  void _sendHeartbeat() {
    if (_tinode == null || !_tinode!.isConnected) {
      _declareDead('Socket not connected');
      return;
    }
    // BNK-581 watchdog: if we've gone quiet past the configured
    // threshold the server has almost certainly reaped the session
    // even though the OS-level socket is still open. Reconnect is
    // the safe response — see Tinode session research in BNK-581.
    final last = _lastInboundAt;
    if (last != null) {
      final gap = DateTime.now().difference(last);
      if (gap > config.inboundIdleThreshold) {
        _declareDead(
          'Inbound watchdog: no server bytes for ${gap.inSeconds}s '
          '(threshold ${config.inboundIdleThreshold.inSeconds}s)',
        );
        return;
      }
    }
    if (_awaitingPong) {
      _declareDead('Previous pong never arrived');
      return;
    }
    try {
      _tinode!.networkProbe();
      _log('Heartbeat: probe sent');
      _awaitingPong = true;
      _pongTimer =
          Timer(config.pongTimeout, () => _declareDead('Pong timeout'));
    } catch (e) {
      _declareDead('Probe send failed: $e');
    }
  }

  void _sendAppKeepalive() {
    final t = _tinode;
    if (t == null || !t.isConnected) return;
    // me.getMeta(withDesc) is the cheapest real request available: it
    // skips data history, doesn't disturb cache, and always returns a
    // {meta} reply. Failure to resolve (which the SDK surfaces after
    // expireFuturesTimeout) means the session is reaped — fall through
    // to _declareDead so reconnect runs even before the inbound
    // watchdog window closes.
    () async {
      try {
        final me = t.getMeTopic();
        await me.getMeta(tinode.MetaGetBuilder(me).withDesc(null).build());
        _log('Heartbeat: app keepalive OK');
      } catch (e) {
        // If the socket was torn down between scheduling and the
        // future resolving, the SDK surfaces the rejection here.
        // _declareDead in that state would race the reconnect path
        // and fire a spurious onDisconnected on the old socket.
        // Only act on this signal if we still believe the socket
        // is up.
        if (_tinode == null || !_tinode!.isConnected) {
          _log('Heartbeat: app keepalive errored after disconnect — '
              'ignoring ($e)');
          return;
        }
        _log('Heartbeat: app keepalive failed: $e');
        _declareDead('App keepalive failed: $e');
      }
    }();
  }

  void _declareDead(String reason) {
    _stopHeartbeat();
    _log('Heartbeat: $reason — declaring connection dead');
    _fire((c) => c.onDisconnected?.call('Heartbeat timeout'));
    _scheduleReconnect();
  }

  // ---------------------------------------------------------------------------
  // Reconnect
  // ---------------------------------------------------------------------------

  Future<void> _ensureConnected() async {
    if (_tinode != null && _tinode!.isConnected) return;
    final state = _connectionState.value;
    if (state == TicTacConnectionState.connecting ||
        state == TicTacConnectionState.reconnecting) {
      await _connectionState.stream
          .firstWhere((s) => s == TicTacConnectionState.connected)
          .timeout(const Duration(seconds: 15));
      return;
    }
    final future = _connectionState.stream
        .firstWhere((s) => s == TicTacConnectionState.connected)
        .timeout(const Duration(seconds: 15));
    _smartReconnect();
    await future;
  }

  Future<void> _smartReconnect() async {
    // If a connect is in flight, don't tear it down — just wait for it.
    // Killing the in-flight Tinode here is what produced the ~55s startup
    // stall: the SDK kept awaiting a socket that had been closed under it.
    final inflight = _connecting;
    if (inflight != null) {
      try {
        await inflight;
      } catch (_) {}
      return;
    }

    _intentionalDisconnect = false;
    _stopHeartbeat();
    _connectionState.add(TicTacConnectionState.reconnecting);

    try {
      _onDisconnectSub?.cancel();
      _onPressSub?.cancel();
      _onSubsUpdatedSub?.cancel();
      _onContactUpdateSub?.cancel();
      _onNetworkProbeSub?.cancel();
      _tinode?.disconnect();
      _tinode = null;

      // connect() itself runs _reattachActiveTopics before firing
      // onConnected, so the topic list a listener receives points at
      // a freshly-resubscribed handle — no separate reattach call
      // needed here.
      await connect();
    } catch (e) {
      _log('Reconnection failed: $e');
    }
  }

  Future<void> _reattachActiveTopics() async {
    final entries = Map.of(_activeTopics);
    for (final entry in entries.entries) {
      final topicId = entry.key;
      final active = entry.value;
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
        active.reattach(topic);
      } catch (e) {
        _log('Failed to reattach topic $topicId: $e');
      }
    }
  }

  void _scheduleReconnect() {
    if (_intentionalDisconnect) return;
    if (_isReconnecting) return;

    _firstFailureTime ??= DateTime.now();
    final elapsed = DateTime.now().difference(_firstFailureTime!);
    if (elapsed >= config.maxReconnectDuration) {
      _log('Reconnect timeout — ${config.maxReconnectDuration.inMinutes}min');
      _connectionState.add(TicTacConnectionState.failed);
      _fire((c) => c.onDisconnected?.call(
        'Chat unavailable — could not reconnect after '
        '${config.maxReconnectDuration.inMinutes} minutes',
      ));
      return;
    }

    _isReconnecting = true;
    _reconnectAttempts++;
    _connectionState.add(TicTacConnectionState.reconnecting);

    final int baseDelayMs;
    if (_reconnectAttempts <= config.aggressiveAttempts) {
      final exponential = config.initialReconnectDelay.inMilliseconds *
          pow(2.0, _reconnectAttempts - 1);
      baseDelayMs =
          min(exponential.toInt(), config.maxAggressiveDelay.inMilliseconds);
    } else {
      baseDelayMs = config.coverInterval.inMilliseconds;
    }
    final jitter =
        baseDelayMs * config.jitterFactor * (2 * _random.nextDouble() - 1);
    final finalDelay =
        Duration(milliseconds: max(100, (baseDelayMs + jitter).round()));

    Future.delayed(finalDelay, () {
      _isReconnecting = false;
      _smartReconnect();
    });
  }

  // ---------------------------------------------------------------------------
  // Authentication
  // ---------------------------------------------------------------------------

  Future<void> _authenticate() async {
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
    final secret = RestAuthSecret(
      appUserId: config.appUserId,
      appId: config.appId,
      appKey: config.appKey,
      provision: config.provision,
    );
    await _tinode!.login('rest', base64.encode(secret.toBytes()), null);
    _cachedToken = _tinode!.getAuthenticationToken();
  }

  // ---------------------------------------------------------------------------
  // Me-topic event handlers
  // ---------------------------------------------------------------------------

  void _handleMePresence(tinode.PresMessage pres) {
    _log('BNK564 _handleMePresence what=${pres.what} src=${pres.src} '
        'topic=${pres.topic} seq=${pres.seq} act=${pres.act} tgt=${pres.tgt}');
    if (pres.src == null) return;
    final what = pres.what;
    if (what != 'on' && what != 'off') {
      _log('BNK564 _handleMePresence SKIP — what=$what (only on/off handled '
          'here; msg/acs/etc. route via onContactUpdate)');
      return;
    }
    final isOnline = what == 'on';
    config.resolveAppUserId(pres.src!).then((appUserId) {
      if (appUserId == null) return;
      _fire((c) => c.onUserPresenceChanged?.call(appUserId, isOnline));
    }).catchError((e) {
      _log('me-presence resolve error: $e');
    });
  }

  /// Diff [_knownTopicIds] against the latest sub dump, fire add/remove
  /// callbacks for deltas.
  void _handleSubsUpdated(List<tinode.TopicSubscription> subs) async {
    _log('BNK564 _handleSubsUpdated: subs.length=${subs.length} '
        'subs=${subs.map((s) => s.topic).toList()}');
    final me = _tinode?.getMeTopic();
    if (me == null) {
      _log('BNK564 _handleSubsUpdated: ABORT — me topic null');
      return;
    }
    final fresh = await _buildTopicList(me);
    final freshIds = fresh.map((t) => t.id).toSet();
    _log('BNK564 _handleSubsUpdated: fresh=$freshIds known=$_knownTopicIds');

    final removed = _knownTopicIds.difference(freshIds);
    for (final id in removed) {
      _log('BNK564 _handleSubsUpdated: REMOVED $id');
      _fire((c) => c.onTopicRemoved?.call(id, 'unsubscribed'));
    }
    final added = freshIds.difference(_knownTopicIds);
    final addedTopics = fresh.where((t) => added.contains(t.id));
    for (final t in addedTopics) {
      _log('BNK564 _handleSubsUpdated: ADDED ${t.id} — firing onTopicAdded '
          '+ scheduling _warmTopic');
      _fire((c) => c.onTopicAdded?.call(t));
      // A topic that just appeared (someone started a chat) may already hold
      // messages — warm it so the app caches them.
      unawaited(_warmTopic(t.id));
    }
    final updated = fresh.where((t) =>
        _knownTopicIds.contains(t.id) && !added.contains(t.id));
    for (final t in updated) {
      _log('BNK564 _handleSubsUpdated: UPDATED ${t.id}');
      _fire((c) => c.onTopicUpdated?.call(t));
    }
    _knownTopicIds
      ..clear()
      ..addAll(freshIds);

    // BNK-568: seed peer online status from the subscription metadata.
    // Tinode populates `sub.online` from the peer's current session state
    // at the time of the meta query (for p2p topics this means "the other
    // party is online"). Re-fire it whenever subs update — for the
    // single-phone "cold mount with peer already online/offline" case it's
    // the only signal we get; for the "peer transitions live" case it's
    // a no-op overwritten by the {pres} frame's onUserPresenceChanged.
    for (final sub in subs) {
      final topicName = sub.topic;
      if (topicName == null) continue;
      // Only p2p user topics carry meaningful per-peer presence. Skip
      // me/fnd/sys and any group topics (grpXXX) where `online` means
      // something else.
      if (!topicName.startsWith('usr')) continue;
      final online = sub.online == true;
      // Resolve fire-and-forget; the resolver may be async (TAGS hop) and
      // we don't want to serialize all subs on a single round trip.
      config.resolveAppUserId(topicName).then((appUserId) {
        if (appUserId == null) return;
        _fire((c) => c.onUserPresenceChanged?.call(appUserId, online));
      }).catchError((e) {
        _log('BNK564 _handleSubsUpdated: seed resolve error topic=$topicName: $e');
      });
    }
  }

  /// Build the app-facing message from a Tinode data message. Shared by the
  /// joined-topic data stream and the fetch-on-presence path so both produce
  /// identical messages. Null if the author can't be resolved.
  Future<types.Message?> _buildMessage(
      String topicId, tinode.DataMessage data) async {
    final from = data.from;
    if (from == null) {
      _log('BNK564 _buildMessage[$topicId] DROP — data.from is null '
          'seq=${data.seq}');
      return null;
    }
    final appUserId = await config.resolveAppUserId(from);
    if (appUserId == null) {
      _log('BNK564 _buildMessage[$topicId] DROP — resolveAppUserId($from) '
          'returned null seq=${data.seq}');
      return null;
    }
    _log('BNK564 _buildMessage[$topicId] OK from=$from -> $appUserId '
        'seq=${data.seq}');

    final author = types.User(id: appUserId);
    final msgId = data.seq?.toString() ?? '';
    final created = data.ts?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
    final status = appUserId == config.appUserId ? types.Status.sent : null;

    final content = data.content;
    if (content is Map && content.containsKey('customType')) {
      return types.CustomMessage(
        id: msgId,
        author: author,
        createdAt: created,
        status: status,
        metadata: {
          'customType': content['customType'],
          if (content['payload'] != null) 'payload': content['payload'],
          if (content['fallbackText'] != null)
            'fallbackText': content['fallbackText'],
        },
      );
    }
    return types.TextMessage(
      id: msgId,
      author: author,
      text: content?.toString() ?? '',
      createdAt: created,
      status: status,
    );
  }

  /// Handle a `me` contact update. A new message on a topic we haven't joined
  /// arrives as `what == 'msg'` (seq bump, no content) — fetch the body and
  /// surface it like a joined-topic message, plus an onTopicUpdated carrying
  /// refreshed unread/touched.
  void _handleContactUpdate(tinode.ContactUpdateEvent ev) {
    final topicName = ev.contact.topic;
    if (topicName == null) {
      _log('BNK564 _handleContactUpdate: SKIP — null topic name');
      return;
    }
    if (topicName == 'me' || topicName == 'fnd' || topicName == 'sys') {
      _log('BNK564 _handleContactUpdate[$topicName] SKIP — system topic');
      return;
    }
    final what = ev.what;
    if (what != 'msg') {
      _log('BNK564 _handleContactUpdate[$topicName] SKIP — what=$what '
          '(only msg + group upd/acs are handled here)');
      return;
    }
    // Joined topics already deliver via their live data stream.
    if (_activeTopics.containsKey(topicName)) {
      _log('BNK564 _handleContactUpdate[$topicName] SKIP — joined topic, '
          'will deliver via live data stream');
      return;
    }
    _log('BNK564 _handleContactUpdate[$topicName] → _fetchAndDeliverLatest');
    _fetchAndDeliverLatest(topicName, ev.contact);
  }

  Future<void> _fetchAndDeliverLatest(
      String topicName, tinode.TopicSubscription sub) async {
    _log('BNK564 _fetchAndDeliverLatest[$topicName] entered');
    final t = _tinode;
    if (t == null) {
      _log('BNK564 _fetchAndDeliverLatest[$topicName] ABORT — _tinode null');
      return;
    }
    if (!_fetchingTopics.add(topicName)) {
      _log('BNK564 _fetchAndDeliverLatest[$topicName] SKIP — '
          'already in _fetchingTopics (warm or fetch in flight)');
      return;
    }

    var subscribedHere = false;
    // {pres what=msg} is the trigger and {data} for the same seq is
    // racing in on the same WS — frequently it lands AFTER getMeta's
    // {ctrl} ack. Without a listener + brief wait, we'd read
    // topic.messages.last before routeData puts the new frame in
    // cache, and surface the previous seq instead of the one the user
    // just sent. Mirrors _warmTopic's pattern with a much shorter wait.
    final collected = <int, tinode.DataMessage>{};
    try {
      final topic = t.getTopic(topicName);
      final dataSub = topic.onData.listen((d) {
        final seq = d?.seq;
        if (seq != null) collected[seq] = d!;
      });
      try {
        final query =
            tinode.MetaGetBuilder(topic).withData(null, null, 1).build();
        if (topic.isSubscribed) {
          // Someone else owns the sub (e.g. createDirectTopic at bootup).
          // The SDK rejects re-subscribe; pull history via getMeta and
          // leave the existing sub alone.
          _log('BNK564 _fetchAndDeliverLatest[$topicName] already subscribed — '
              'getMeta(withData null,null,1)');
          await topic.getMeta(query);
        } else {
          await topic.subscribe(query, null);
          subscribedHere = true;
        }
        // Drain late-arriving {data} frames for this seq before reading.
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } finally {
        await dataSub.cancel();
      }
      // Merge live captures with topic cache so a frame is picked up
      // whether routeData or our listener saw it first.
      for (final d in topic.messages) {
        final seq = d.seq;
        if (seq != null) collected[seq] = d;
      }
      _log('BNK564 _fetchAndDeliverLatest[$topicName] ctrl OK, '
          'collected=${collected.length} cache=${topic.messages.length}');
      if (collected.isNotEmpty) {
        // Do NOT markRead — a background fetch must not advance the read
        // marker, or it would wipe the unread count.
        final latest = collected.values.reduce(
            (a, b) => (a.seq ?? 0) >= (b.seq ?? 0) ? a : b);
        final msg = await _buildMessage(topicName, latest);
        if (msg != null) {
          _log('BNK564 _fetchAndDeliverLatest[$topicName] firing '
              'onMessageReceived seq=${latest.seq}');
          _fire((c) => c.onMessageReceived?.call(topicName, msg));
        } else {
          _log('BNK564 _fetchAndDeliverLatest[$topicName] _buildMessage '
              'returned null — message dropped');
        }
      } else {
        _log('BNK564 _fetchAndDeliverLatest[$topicName] no messages — '
            'nothing to deliver');
      }
      if (subscribedHere) {
        await topic.leave(false);
      }
    } catch (e) {
      _log('BNK564 _fetchAndDeliverLatest[$topicName] EXCEPTION: $e');
    } finally {
      _fetchingTopics.remove(topicName);
    }

    final updated = await _buildTopicFromSub(sub);
    if (updated != null) {
      _fire((c) => c.onTopicUpdated?.call(updated));
    }
  }

  /// Build a single tictac Topic from a `me` contact subscription — no extra
  /// desc round-trip (uses the cached `fn`), for cheap onTopicUpdated events.
  Future<tictac_models.Topic?> _buildTopicFromSub(
      tinode.TopicSubscription sub) async {
    final topicName = sub.topic;
    if (topicName == null) return null;
    final isP2P = tinode.Tools.isP2PTopicName(topicName);
    final isGroup = tinode.Tools.isGroupTopicName(topicName);
    if (!isP2P && !isGroup) return null;

    String? displayName;
    if (sub.public is Map) displayName = (sub.public as Map)['fn'];

    final memberIds = <String>[];
    if (isP2P) {
      final otherAppUserId = await config.resolveAppUserId(topicName);
      if (otherAppUserId != null) {
        memberIds.add(otherAppUserId);
        displayName ??= otherAppUserId;
      }
    }

    return tictac_models.Topic(
      id: topicName,
      name: displayName,
      type: isP2P ? TopicType.direct : TopicType.group,
      memberAppUserIds: memberIds,
      memberCount: isP2P ? 2 : (sub.seq ?? 0),
      unreadCount: sub.unread ?? 0,
      lastActivity: sub.touched,
    );
  }

  static bool _isCustomData(tinode.DataMessage d) =>
      d.content is Map && (d.content as Map).containsKey('customType');

  /// Warm a topic's cache: fetch recent history and replay the **last text**
  /// and **last custom** message through onMessageReceived. This surfaces
  /// messages that were already in the topic before this session — a chat
  /// someone else started, or anything that arrived while logged out — which
  /// never generate a live `msg` presence. Skips joined topics (joinTopic
  /// already replays their history).
  Future<void> _warmTopic(String topicName, {int scan = 30}) async {
    _log('BNK564 _warmTopic[$topicName] entered scan=$scan');
    final t = _tinode;
    if (t == null) {
      _log('BNK564 _warmTopic[$topicName] ABORT — _tinode null');
      return;
    }
    if (topicName == 'me' || topicName == 'fnd' || topicName == 'sys') {
      _log('BNK564 _warmTopic[$topicName] SKIP — system topic');
      return;
    }
    if (_activeTopics.containsKey(topicName)) {
      _log('BNK564 _warmTopic[$topicName] SKIP — already joined');
      return;
    }
    if (!_fetchingTopics.add(topicName)) {
      _log('BNK564 _warmTopic[$topicName] SKIP — already in _fetchingTopics '
          '(another warm or fetch is in flight)');
      return; // in flight (warm or live fetch)
    }

    // seq -> message, deduped. Collect from the data stream (frames can land
    // just after the subscribe ctrl resolves) and from the topic's cache.
    final collected = <int, tinode.DataMessage>{};
    var subscribedHere = false;
    try {
      final topic = t.getTopic(topicName);
      _log('BNK564 _warmTopic[$topicName] getTopic OK '
          'topic.messages.length(pre-sub)=${topic.messages.length} '
          'isSubscribed=${topic.isSubscribed}');
      final dataSub = topic.onData.listen((d) {
        final seq = d?.seq;
        _log('BNK564 _warmTopic[$topicName] onData frame seq=$seq from=${d?.from}');
        if (seq != null) collected[seq] = d!;
      });
      try {
        // withData(null,null,limit) = latest `scan` messages. (withLaterData is
        // a no-op until a topic has loaded data, so it can't do a fresh fetch.)
        final query =
            tinode.MetaGetBuilder(topic).withData(null, null, scan).build();
        if (topic.isSubscribed) {
          // Someone already owns the sub (e.g. createDirectTopic at
          // bootup). Don't re-subscribe — the SDK rejects that. Just
          // pull history via getMeta and leave the existing sub alone.
          _log('BNK564 _warmTopic[$topicName] already subscribed — '
              'getMeta(withData null,null,$scan)');
          await topic.getMeta(query);
        } else {
          _log('BNK564 _warmTopic[$topicName] subscribing with '
              'withData(null,null,$scan)');
          await topic.subscribe(query, null);
          subscribedHere = true;
        }
        _log('BNK564 _warmTopic[$topicName] ctrl returned, '
            'waiting for data frames…');
        // Late {data} frames can arrive after the {ctrl} ack — give them
        // a window to land before we read topic.messages.
        await Future<void>.delayed(const Duration(milliseconds: 3000));
        _log('BNK564 _warmTopic[$topicName] wait done '
            'topic.messages.length(post-wait)=${topic.messages.length}');
      } finally {
        await dataSub.cancel();
      }
      for (final d in topic.messages) {
        final seq = d.seq;
        if (seq != null) collected[seq] = d;
      }
      // Only leave if we did the subscribing in this call AND no one
      // joined this topic in the meantime. Tearing down a sub owned by
      // another caller (createDirectTopic, joinTopic, OR a chat-screen
      // mount that raced our warm) would silently break their live
      // data flow.
      if (subscribedHere && !_activeTopics.containsKey(topicName)) {
        await topic.leave(false);
      } else if (subscribedHere) {
        _log('BNK564 _warmTopic[$topicName] SKIP leave — joined during warm');
      }
    } catch (e) {
      _log('BNK564 _warmTopic[$topicName] EXCEPTION: $e');
    } finally {
      _fetchingTopics.remove(topicName);
    }

    final all = collected.values.toList()
      ..sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0));
    _log('BNK564 _warmTopic[$topicName] fetch complete — ${all.length} '
        'message(s) collected '
        'seqs=${all.map((d) => d.seq).toList()}');

    // Ascending by seq, so the last assignment of each kind is the newest.
    tinode.DataMessage? lastText;
    tinode.DataMessage? lastCustom;
    for (final d in all) {
      if (_isCustomData(d)) {
        lastCustom = d;
      } else {
        lastText = d;
      }
    }
    final picks = <tinode.DataMessage>[
      if (lastText != null) lastText,
      if (lastCustom != null) lastCustom,
    ]..sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0));
    for (final d in picks) {
      final msg = await _buildMessage(topicName, d);
      if (msg != null) {
        _fire((c) => c.onMessageReceived?.call(topicName, msg));
      }
    }
  }

  /// Warm all topics with bounded concurrency so a large list doesn't fire a
  /// storm of subscribes at connect.
  Future<void> _warmAllTopics(List<tictac_models.Topic> topics) async {
    const batchSize = 4;
    for (var i = 0; i < topics.length; i += batchSize) {
      await Future.wait(topics.skip(i).take(batchSize).map((t) => _warmTopic(t.id)));
    }
  }

  Future<List<tictac_models.Topic>> _buildTopicList(tinode.TopicMe me) async {
    final topics = <tictac_models.Topic>[];
    for (final sub in me.contacts) {
      if (sub.topic == null) continue;
      final topicName = sub.topic!;
      if (topicName == 'me' || topicName == 'fnd' || topicName == 'sys') {
        continue;
      }
      final isP2P = tinode.Tools.isP2PTopicName(topicName);
      final isGroup = tinode.Tools.isGroupTopicName(topicName);
      if (!isP2P && !isGroup) continue;

      String? displayName;
      if (sub.public != null && sub.public is Map) {
        displayName = (sub.public as Map)['fn'];
      }

      final memberIds = <String>[];
      if (isP2P) {
        final otherAppUserId = await config.resolveAppUserId(topicName);
        if (otherAppUserId != null) {
          memberIds.add(otherAppUserId);
          displayName ??= otherAppUserId;
        }
      }

      topics.add(tictac_models.Topic(
        id: topicName,
        name: displayName,
        type: isP2P ? TopicType.direct : TopicType.group,
        memberAppUserIds: memberIds,
        memberCount: isP2P ? 2 : (sub.seq ?? 0),
        unreadCount: sub.unread ?? 0,
        lastActivity: sub.touched,
      ));
    }
    return topics;
  }

  void _log(String message) {
    // ignore: avoid_print
    print('TicTac: $message');
  }
}

// ===========================================================================
// _ActiveTopic — internal, holds a tinode.Topic subscription's stream
// listeners and the public TopicHandle. Created on joinTopic, disposed
// on leave / deleteTopic / module dispose. No external accessors.
// ===========================================================================

class _ActiveTopic {
  final String topicId;
  final TicTacModule module;
  tinode.Topic _topic;
  late final _TopicHandleImpl handle;

  StreamSubscription? _dataSub;
  StreamSubscription? _presSub;
  StreamSubscription? _infoSub;
  StreamSubscription? _metaSubSub;
  StreamSubscription? _delMessagesSub;

  bool _disposed = false;

  _ActiveTopic({
    required this.topicId,
    required tinode.Topic topic,
    required this.module,
  }) : _topic = topic {
    handle = _TopicHandleImpl(this);
  }

  /// Re-fire onMessageReceived for every message currently in the SDK's
  /// local cache. Used when a UI rejoins an already-active topic so it
  /// can populate without hitting the network. Listeners are expected to
  /// dedupe by message id (TicTacChat already does this).
  void replayCachedMessages() {
    if (_disposed) return;
    for (final data in _topic.messages) {
      _onData(data);
    }
  }

  /// Highest read marker across non-self subscribers, or 0 if none. Lets
  /// a re-mounted UI seed its peer-read state synchronously instead of
  /// waiting for the next live `{info what=read}` from the server.
  int peerReadSeq() {
    final t = module._tinode;
    final selfId = t != null && t.isAuthenticated ? t.userId : null;
    return PeerReadState.maxPeerRead(_topic.subscribers.values, selfId);
  }

  /// Per-member view of [peerReadSeq] keyed by appUserId. Resolves each
  /// non-self Tinode subscriber to an appUserId via the host's
  /// resolver; subscribers that don't resolve are dropped silently.
  Future<Map<String, int>> peerReadSeqs() async {
    final t = module._tinode;
    final selfId = t != null && t.isAuthenticated ? t.userId : null;
    final tinodeKeyed = PeerReadState.peerReadSeqsByUser(
      _topic.subscribers.values,
      selfId,
    );
    final out = <String, int>{};
    for (final entry in tinodeKeyed.entries) {
      final appUid = await module.config.resolveAppUserId(entry.key);
      if (appUid == null) continue;
      out[appUid] = entry.value;
    }
    return out;
  }

  void attach() {
    _dataSub?.cancel();
    _dataSub = _topic.onData.listen(_onData);
    _presSub?.cancel();
    _presSub = _topic.onPres.listen(_onPres);
    _infoSub?.cancel();
    _infoSub = _topic.onInfo.listen(_onInfo);
    _metaSubSub?.cancel();
    _metaSubSub = _topic.onMetaSub.listen(_onMetaSub);
    // Note: tinode.dart's Topic doesn't currently expose a per-message
    // delete stream — onMessageDeleted is best-effort via the data
    // stream's tombstone messages. Wire up when the SDK gains a proper
    // event.
  }

  void reattach(tinode.Topic topic) {
    _topic = topic;
    attach();
  }

  void _onData(tinode.DataMessage? data) {
    if (data == null) return;
    module._buildMessage(topicId, data).then((msg) {
      if (msg == null) return;
      module._fire((c) => c.onMessageReceived?.call(topicId, msg));
    }).catchError((e) {
      module._log('topic($topicId): data resolve error: $e');
    });
  }

  void _onPres(tinode.PresMessage? pres) {
    if (pres == null) return;
    if (pres.what != 'on' && pres.what != 'off') return;
    final tinodeUserId = pres.src;
    if (tinodeUserId == null) return;
    final isOnline = pres.what == 'on';
    module.config.resolveAppUserId(tinodeUserId).then((appUserId) {
      if (appUserId == null) return;
      module._fire((c) => c.onTopicPresenceChanged?.call(topicId, appUserId, isOnline));
    }).catchError((e) {
      module._log('topic($topicId): pres resolve error: $e');
    });
  }

  void _onInfo(tinode.InfoMessage info) {
    final from = info.from;
    if (from == null) return;
    switch (info.what) {
      case 'kp':
        module.config.resolveAppUserId(from).then((appUserId) {
          if (appUserId == null || appUserId == module.config.appUserId) return;
          module._fire((c) => c.onTypingStarted?.call(topicId, appUserId));
        }).catchError((e) {
          module._log('topic($topicId): typing resolve error: $e');
        });
        break;
      case 'read':
        final seq = info.seq;
        if (seq == null) return;
        module.config.resolveAppUserId(from).then((appUserId) {
          if (appUserId == null) return;
          // Fires for ALL readers including the current user. Tinode
          // cross-device sync echoes our own reads to other sessions of
          // the same user, and consumers that need to track "I've read
          // up to here" (host topic-list caches) want both directions.
          // Consumers that distinguish peer-read from self-read must
          // filter on appUserId.
          module._fire((c) => c.onMessageRead?.call(topicId, appUserId, seq));
        }).catchError((e) {
          module._log('topic($topicId): read resolve error: $e');
        });
        break;
      // 'recv' (delivered) intentionally not surfaced — TicTac models only
      // sent/seen, not a separate delivered state.
    }
  }

  void _onMetaSub(tinode.TopicSubscription sub) {
    if (sub.user == null) return;
    // Tinode routes member adds AND removes through the same
    // onMetaSub stream — only the resulting access mode tells them
    // apart. If the sub is marked deleted or the effective mode no
    // longer has the Join bit, the user has been ejected / has left;
    // anything else is "joined / membership active." Without this
    // distinction every mid-life ejection looked like a fresh add to
    // the host (see BNK-603 phase 7 / BNK-635 / BNK-638 thread).
    final removed = sub.deleted != null || !_subHasJoin(sub);
    // Fast path: appUserId in public profile.
    String? appUserId;
    if (sub.public != null && sub.public is Map) {
      appUserId = (sub.public as Map)['appUserId'];
    }
    if (appUserId != null && appUserId.isNotEmpty) {
      _fireMember(appUserId, sub, removed: removed);
      return;
    }
    module.config.resolveAppUserId(sub.user!).then((resolved) {
      if (resolved == null) return;
      _fireMember(resolved, sub, removed: removed);
    }).catchError((e) {
      module._log('topic($topicId): metaSub resolve error: $e');
    });
  }

  bool _subHasJoin(tinode.TopicSubscription sub) {
    final acs = sub.acs;
    if (acs == null) return true; // unknown — default to "still a member"
    return (acs.mode & access_mode.JOIN) != 0;
  }

  void _fireMember(String appUserId, tinode.TopicSubscription sub,
      {required bool removed}) {
    if (removed) {
      module._fire((c) => c.onMemberRemoved?.call(topicId, appUserId));
      return;
    }
    final member = types.User(id: appUserId);
    module._fire((c) => c.onMemberAdded?.call(topicId, member));
    final online = sub.online;
    if (online != null) {
      module._fire((c) => c.onTopicPresenceChanged?.call(topicId, appUserId, online));
    }
    // Surface the subscriber's read marker so "seen" state (own
    // messages) and "I've caught up" state (self) are correct on
    // join. Live updates arrive separately via onInfo what=read.
    // Fires for self too — consumers distinguish on appUserId.
    final readSeq = sub.read;
    if (readSeq != null && readSeq > 0) {
      module._fire((c) => c.onMessageRead?.call(topicId, appUserId, readSeq));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _dataSub?.cancel();
    await _presSub?.cancel();
    await _infoSub?.cancel();
    await _metaSubSub?.cancel();
    await _delMessagesSub?.cancel();
  }

  // ---- TopicHandle delegate methods ----

  Future<void> sendText(String text) async {
    final msg = _topic.createMessage(text, true);
    await _topic.publishMessage(msg);
  }

  Future<void> sendCustom(
    String customType,
    Map<String, dynamic> payload, {
    String? fallbackText,
  }) async {
    // `txt` makes the content valid Drafty (the format Tinode expects).
    // Without it, Tinode's drafty.PlainText errors out and tnpg drops
    // the entire push silently — recipients never see a notification.
    // Receiving clients still parse customType/payload/fallbackText at
    // the top level; `txt` is additive and ignored by them.
    final content = {
      'txt': fallbackText ?? '',
      'customType': customType,
      'payload': payload,
      'fallbackText': fallbackText ?? '',
    };
    final msg = _topic.createMessage(content, true);
    await _topic.publishMessage(msg);
  }

  Future<void> markRead(String messageId) async {
    final seq = int.tryParse(messageId);
    if (seq == null) return;
    _topic.noteRead(seq);
    // Tinode does not echo our own `{note what=read}` back to the same
    // session, and the server-side meta sub refresh that would update
    // cont.read is asynchronous and may never reach us in this session.
    // Fire onMessageRead locally so consumers (TicTacChat, host topic-
    // list caches) can advance their "I've read up to here" state right
    // now. The callback receives our own appUserId; consumers that
    // distinguish peer-read from self-read must filter on the readerId.
    module._fire((c) => c.onMessageRead?.call(
        topicId, module.config.appUserId, seq));
  }

  Future<void> setTyping(bool isTyping) async {
    if (!isTyping) return; // protocol has no "stop typing" event
    _topic.noteKeyPress();
  }

  Future<void> deleteMessage(String messageId) async {
    final seq = int.tryParse(messageId);
    if (seq == null) return;
    await _topic.deleteMessages(
      [tinode.DelRange(low: seq, hi: seq + 1)],
      true,
    );
  }

  Future<void> leave() async {
    // Idempotent: TicTacChat owns the topic's lifecycle and calls leave
    // from its dispose, while host code (the bridge) may also call leave
    // from its own dispose path. Without this guard, the second call
    // re-fires Topic.leave on an already-left subscription, surfacing
    // "Cannot publish on inactive topic" exceptions.
    if (_disposed) return;
    await dispose();
    module._activeTopics.remove(topicId);
    // Topic.leave does two things we need: (a) sends LEAVE on the
    // wire, (b) calls resetSubscription() to clear the local
    // `_subscribed` flag so the next join re-issues a SUB and re-fetches
    // cached messages. Routing through Tinode.leave directly skips (b),
    // which means a subsequent joinTopic sees `isSubscribed=true` and
    // silently skips the SUB → no message replay.
    //
    // Topic.leave throws a `'CtrlMessage' is not a subtype of
    // 'Map<String, dynamic>'` cast error AFTER both (a) and (b) have
    // completed (the cast is on the return value). Swallow it so the
    // caller doesn't see a phantom failure.
    try {
      await _topic.leave(false);
    } catch (e) {
      module._log('Topic.leave swallowed cast: $e');
    }
  }

  Future<void> invite(String appUserId) async {
    final tinodeUid = await _resolveOne(appUserId);
    await _topic.invite(tinodeUid, _kDefaultMemberMode);
  }

  Future<void> eject(String appUserId) async {
    final tinodeUid = await _resolveOne(appUserId);
    await _topic.invite(tinodeUid, _kEjectMode);
  }

  Future<void> setName(String name) async {
    await _topic.setMeta(tinode.SetParams()
      ..desc = (tinode.TopicDescription()..public = {'fn': name}));
  }

  Future<void> setPhoto(String url) async {
    await _topic.setMeta(tinode.SetParams()
      ..desc = (tinode.TopicDescription()..public = {'photo': url}));
  }

  Future<String> _resolveOne(String appUserId) async {
    final resolver = module.config.resolveTinodeUserIds;
    if (resolver == null) {
      throw StateError(
          'invite/eject require TicTacConfig.resolveTinodeUserIds');
    }
    final mappings = await resolver([appUserId]);
    final tinodeUid = mappings[appUserId];
    if (tinodeUid == null) {
      throw ArgumentError.value(
          appUserId, 'appUserId', 'cannot resolve to a Tinode user id');
    }
    return tinodeUid;
  }
}

/// Thin facade — delegates everything to `_ActiveTopic`. Exists so the
/// public type doesn't leak `_ActiveTopic`'s internals.
class _TopicHandleImpl implements TopicHandle {
  final _ActiveTopic _active;
  _TopicHandleImpl(this._active);

  @override
  String get topicId => _active.topicId;

  @override
  Future<void> sendText(String text) => _active.sendText(text);

  @override
  Future<void> sendCustom(
    String customType,
    Map<String, dynamic> payload, {
    String? fallbackText,
  }) =>
      _active.sendCustom(customType, payload, fallbackText: fallbackText);

  @override
  Future<void> markRead(String messageId) => _active.markRead(messageId);

  @override
  Future<void> setTyping(bool isTyping) => _active.setTyping(isTyping);

  @override
  Future<void> deleteMessage(String messageId) =>
      _active.deleteMessage(messageId);

  @override
  Future<void> leave() => _active.leave();

  @override
  int peerReadSeq() => _active.peerReadSeq();

  @override
  Future<Map<String, int>> peerReadSeqs() => _active.peerReadSeqs();

  @override
  Future<void> invite(String appUserId) => _active.invite(appUserId);

  @override
  Future<void> eject(String appUserId) => _active.eject(appUserId);

  @override
  Future<void> setName(String name) => _active.setName(name);

  @override
  Future<void> setPhoto(String url) => _active.setPhoto(url);
}
