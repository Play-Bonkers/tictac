import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:tictac/tictac.dart';

void main() {
  const tinodeHost = '44.234.36.7';
  const tinodePort = 6060;
  const appId = 'd9c3780a-8be6-4d7c-8572-3272e985a415';
  const appKey = 'x8eKwfsOHH_hTXNSdTUhEMmBlJ9QB4g34zdg2k8IuFI';

  int _counter = 0;
  String uniqueUserId() => 'recontest-${DateTime.now().millisecondsSinceEpoch}-${_counter++}';

  TicTacConfig makeConfig(String appUserId, {
    Duration heartbeatInterval = const Duration(seconds: 3),
    Duration pongTimeout = const Duration(seconds: 2),
  }) {
    return TicTacConfig(
      tinodeHost: tinodeHost,
      tinodePort: tinodePort,
      appUserId: appUserId,
      appId: appId,
      appKey: appKey,
      sessionId: 'test-session',
      generateRequestId: () => 'req-${DateTime.now().millisecondsSinceEpoch}',
      heartbeatInterval: heartbeatInterval,
      pongTimeout: pongTimeout,
      backgroundReconnectThreshold: const Duration(seconds: 2),
    );
  }

  // -------------------------------------------------------------------------
  // Connection state stream
  // -------------------------------------------------------------------------

  group('Connection state', () {
    test('starts as disconnected', () {
      final module = TicTacModule(makeConfig(uniqueUserId()));
      expect(module.currentConnectionState, TicTacConnectionState.disconnected);
    });

    test('transitions to connecting then connected', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));

      final states = <TicTacConnectionState>[];
      final sub = module.connectionState.listen(states.add);

      await module.connect();

      // Give stream time to deliver
      await Future.delayed(Duration(milliseconds: 100));

      expect(states, contains(TicTacConnectionState.connecting));
      expect(states, contains(TicTacConnectionState.connected));
      expect(module.currentConnectionState, TicTacConnectionState.connected);

      sub.cancel();
      await module.disconnect();
    });

    test('transitions to disconnected on intentional disconnect', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      final states = <TicTacConnectionState>[];
      final sub = module.connectionState.listen(states.add);

      await module.disconnect();
      await Future.delayed(Duration(milliseconds: 100));

      expect(states, contains(TicTacConnectionState.disconnected));
      expect(module.currentConnectionState, TicTacConnectionState.disconnected);

      sub.cancel();
    });
  });

  // -------------------------------------------------------------------------
  // Heartbeat
  // -------------------------------------------------------------------------

  group('Heartbeat', () {
    test('connection stays alive with active heartbeat', () async {
      final userId = uniqueUserId();
      // Short heartbeat interval for testing
      final module = TicTacModule(makeConfig(userId, heartbeatInterval: Duration(seconds: 2)));
      await module.connect();
      expect(module.currentConnectionState, TicTacConnectionState.connected);

      // Wait through 2 heartbeat cycles
      await Future.delayed(Duration(seconds: 5));

      // Should still be connected (heartbeat kept it alive)
      expect(module.currentConnectionState, TicTacConnectionState.connected);
      expect(module.isConnected, isTrue);

      await module.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // App lifecycle
  // -------------------------------------------------------------------------

  group('App lifecycle', () {
    test('handleAppLifecycleState paused then quick resume stays connected', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      // Simulate brief background (< threshold)
      module.handleAppLifecycleState(AppLifecycleState.paused);
      await Future.delayed(Duration(milliseconds: 500));
      module.handleAppLifecycleState(AppLifecycleState.resumed);

      await Future.delayed(Duration(seconds: 1));
      expect(module.currentConnectionState, TicTacConnectionState.connected);

      await module.disconnect();
    });

    test('handleAppLifecycleState paused then long resume triggers reconnect', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId,
        heartbeatInterval: Duration(seconds: 30), // prevent heartbeat interference
      ));
      await module.connect();

      final states = <TicTacConnectionState>[];
      final sub = module.connectionState.listen(states.add);

      // Simulate long background (> 2s threshold set in config)
      module.handleAppLifecycleState(AppLifecycleState.paused);
      await Future.delayed(Duration(seconds: 3));
      module.handleAppLifecycleState(AppLifecycleState.resumed);

      // Wait for reconnect to complete
      await Future.delayed(Duration(seconds: 5));

      expect(states, contains(TicTacConnectionState.reconnecting));
      // Should end up connected again
      expect(module.currentConnectionState, TicTacConnectionState.connected);

      sub.cancel();
      await module.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // TopicController re-attachment
  // -------------------------------------------------------------------------

  group('TopicController re-attachment', () {
    test('topic controller works after forced reconnect', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId,
        heartbeatInterval: Duration(seconds: 30),
      ));
      await module.connect();

      // Create topic and join
      final topic = await module.createGroupTopic('reattach-test', []);
      final controller = await module.joinTopic(topic.id);

      // Send a message to verify it works before reconnect
      await controller.sendMessage(
        const types.PartialText(text: 'before reconnect'),
      );
      await Future.delayed(Duration(seconds: 2));
      expect(controller.messages.any((m) =>
          m is types.TextMessage && m.text == 'before reconnect'), isTrue);

      // Force reconnect
      module.reconnect();
      await Future.delayed(Duration(seconds: 5));

      expect(module.currentConnectionState, TicTacConnectionState.connected);
      expect(controller.isConnected, isTrue);

      // Send a message after reconnect
      await controller.sendMessage(
        const types.PartialText(text: 'after reconnect'),
      );
      await Future.delayed(Duration(seconds: 2));
      expect(controller.messages.any((m) =>
          m is types.TextMessage && m.text == 'after reconnect'), isTrue,
        reason: 'Should be able to send after reconnect');

      await module.deleteTopic(topic.id, hard: true);
      await module.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // Pre-operation health check
  // -------------------------------------------------------------------------

  group('Pre-operation health check', () {
    test('ensureConnected waits for ongoing reconnect', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId,
        heartbeatInterval: Duration(seconds: 30),
      ));
      await module.connect();

      // Trigger reconnect
      module.reconnect();

      // Immediately try an operation — should wait for reconnect
      final topics = await module.getTopics();
      expect(topics, isA<List<Topic>>());

      await module.disconnect();
    });

    test('createGroupTopic succeeds after reconnect', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId,
        heartbeatInterval: Duration(seconds: 30),
      ));
      await module.connect();

      // Force reconnect
      module.reconnect();
      await Future.delayed(Duration(seconds: 3));

      // Operation should work after reconnect
      final topic = await module.createGroupTopic('health-check-test', []);
      expect(topic.id, isNotEmpty);

      await module.deleteTopic(topic.id, hard: true);
      await module.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // Silent socket death detection
  // -------------------------------------------------------------------------

  group('Silent socket death', () {
    test('connection state is connected after successful connect', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      expect(module.currentConnectionState, TicTacConnectionState.connected);
      expect(module.isConnected, isTrue);

      await module.disconnect();
    });
  });
}
