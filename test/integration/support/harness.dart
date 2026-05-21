import 'dart:async';

import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:tictac/tictac.dart';

/// Single point of truth for the dev integration test wiring: which Tinode
/// to talk to, which app credentials to use, how to build a [TicTacConfig]
/// and a [TicTacModule] with event-collecting callbacks.
///
/// One [Harness] per test — each call to [Harness.boot] mints a fresh
/// app-user-id so tests don't share Tinode accounts.
class Harness {
  /// Direct Tinode dev endpoint (TAGS-bypass). Tests assert against the
  /// raw Tinode protocol; running through the TAGS gateway adds an extra
  /// auth dimension that's out of scope for the chat-protocol tests.
  static const String tinodeHost = '44.234.36.7';
  static const int tinodePort = 6060;

  /// App credentials accepted by the REST auth Lambda's `provision: true`
  /// path. These mint new Tinode accounts on demand for tests.
  static const String appId = 'd9c3780a-8be6-4d7c-8572-3272e985a415';
  static const String appKey = 'x8eKwfsOHH_hTXNSdTUhEMmBlJ9QB4g34zdg2k8IuFI';

  static int _counter = 0;

  /// Unique app-user-id for the current test run. Includes a millisecond
  /// timestamp + counter so parallel tests don't collide.
  static String uniqueUserId() =>
      'inttest-${DateTime.now().millisecondsSinceEpoch}-${_counter++}';

  final String appUserId;
  final TicTacModule module;
  final List<_MessageEntry> _messages;
  final List<_ReadEntry> _reads;

  Completer<List<Topic>> _connected;

  Harness._(
      this.appUserId, this.module, this._connected, this._messages, this._reads);

  /// Build a harness with a freshly-generated app-user-id.
  factory Harness.boot() => bootWithUserId(uniqueUserId());

  /// Build a harness for the given app-user-id. Used by tests that
  /// need to reconnect as the same user across two module instances
  /// (cold-restart scenarios).
  static Harness bootWithUserId(String appUserId) {
    final connected = Completer<List<Topic>>();
    final messages = <_MessageEntry>[];
    final reads = <_ReadEntry>[];
    late Harness h;

    final config = TicTacConfig(
      tinodeHost: tinodeHost,
      tinodePort: tinodePort,
      secure: false,
      appUserId: appUserId,
      appId: appId,
      appKey: appKey,
      sessionId: 'test-${DateTime.now().millisecondsSinceEpoch}',
      generateRequestId: () =>
          'req-${DateTime.now().microsecondsSinceEpoch}',
      authTokenProvider: () async => null,
      // Tests don't run TAGS; pass through the tinode uid as the app uid.
      // Two-user tests can override by seeding via a custom factory.
      resolveAppUserId: (tinodeUid) async => tinodeUid,
      provision: true,
    );

    final callbacks = TicTacCallbacks(
      onConnected: (topics) {
        if (!h._connected.isCompleted) h._connected.complete(topics);
      },
      onMessageReceived: (topicId, msg) {
        messages.add(_MessageEntry(topicId, msg));
      },
      onMessageRead: (topicId, appUserId, seq) {
        reads.add(_ReadEntry(topicId, appUserId, seq));
      },
    );

    final module = TicTacModule(config, callbacks);
    h = Harness._(appUserId, module, connected, messages, reads);
    return h;
  }

  /// Wait for `onConnected` to fire and return the topic list it carried.
  /// Default timeout is generous because cold provisioning can take a few
  /// seconds.
  Future<List<Topic>> awaitConnected({
    Duration timeout = const Duration(seconds: 15),
  }) {
    return _connected.future.timeout(timeout);
  }

  /// Reset the connected completer so the next reconnect can be awaited.
  /// Tests call this before invoking `module.reconnect()`.
  void resetConnected() {
    _connected = Completer<List<Topic>>();
  }

  /// All messages received so far (across all topics).
  List<_MessageEntry> get allMessages => List.unmodifiable(_messages);

  /// Drop the local message buffer. Useful before a reconnect / rejoin
  /// when you want to assert only on post-event arrivals.
  void clearMessages() => _messages.clear();

  /// Poll until a message matching [predicate] arrives on [topicId], or
  /// [timeout] expires. Polling cadence is 100ms — fast enough for a
  /// human-paced test, lazy enough that we don't spin the event loop.
  Future<types.Message> awaitMessage({
    required String topicId,
    required bool Function(types.Message msg) predicate,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (final entry in _messages) {
        if (entry.topicId == topicId && predicate(entry.message)) {
          return entry.message;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException(
      'Timed out after ${timeout.inSeconds}s waiting for matching message '
      'on topic $topicId (received ${_messages.length} so far)',
    );
  }

  /// All read receipts surfaced so far (peer marked messages read).
  List<_ReadEntry> get allReads => List.unmodifiable(_reads);

  /// Poll until a read receipt matching [predicate] arrives on [topicId].
  /// Used by two-client tests: A waits for B's `onMessageRead`.
  Future<_ReadEntry> awaitRead({
    required String topicId,
    required bool Function(_ReadEntry read) predicate,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (final entry in _reads) {
        if (entry.topicId == topicId && predicate(entry)) return entry;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException(
      'Timed out after ${timeout.inSeconds}s waiting for a read receipt '
      'on topic $topicId (received ${_reads.length} so far)',
    );
  }

  /// Tear down the module's websocket. Tests should always call this in a
  /// teardown / at the end of the test body so the connection doesn't
  /// linger between tests.
  Future<void> dispose() async {
    try {
      await module.disconnect();
    } catch (_) {
      // disconnect can throw if we never connected; tolerate.
    }
  }
}

class _MessageEntry {
  final String topicId;
  final types.Message message;
  _MessageEntry(this.topicId, this.message);
}

class _ReadEntry {
  final String topicId;
  final String appUserId;
  final int seq;
  _ReadEntry(this.topicId, this.appUserId, this.seq);
}
