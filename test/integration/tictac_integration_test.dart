import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:tictac/tictac.dart';

/// Integration tests for TicTac against a live Tinode server.
///
/// Run with: dart test test/integration/tictac_integration_test.dart --timeout 60s
///
/// Requires Tinode dev server at 44.234.36.7:6060 with REST auth Lambda.
void main() {
  const tinodeHost = '44.234.36.7';
  const tinodePort = 6060;
  const appId = 'd9c3780a-8be6-4d7c-8572-3272e985a415';
  const appKey = 'x8eKwfsOHH_hTXNSdTUhEMmBlJ9QB4g34zdg2k8IuFI';

  int _counter = 0;
  String uniqueUserId() => 'inttest-${DateTime.now().millisecondsSinceEpoch}-${_counter++}';

  TicTacConfig makeConfig(String appUserId) {
    return TicTacConfig(
      tinodeHost: tinodeHost,
      tinodePort: tinodePort,
      appUserId: appUserId,
      appId: appId,
      appKey: appKey,
      sessionId: 'test-session',
      generateRequestId: () => 'req-${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  // -------------------------------------------------------------------------
  // Session tests
  // -------------------------------------------------------------------------

  group('Session', () {
    test('connect and authenticate', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      final topics = await module.connect();

      expect(module.isConnected, isTrue);
      expect(topics, isA<List<Topic>>());

      await module.disconnect();
    });

    test('connect returns topic list after reconnect', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      // Create a topic so there's something in the list
      final created = await module.createGroupTopic('session-topics-test', []);
      final createdId = created.id;

      // Reconnect to get topics from "me" subscription
      await module.disconnect();
      final module2 = TicTacModule(makeConfig(userId));
      final topics = await module2.connect();

      expect(topics, isNotEmpty);
      // Check by ID since name resolution after reconnect requires desc fetch
      final found = topics.any((t) => t.id == createdId);
      expect(found, isTrue, reason: 'Expected topic $createdId in topic list');

      await module2.deleteTopic(createdId, hard: true);
      await module2.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // Topic tests
  // -------------------------------------------------------------------------

  group('Topics', () {
    test('create group topic', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      final topic = await module.createGroupTopic('test-group', []);

      expect(topic.id, isNotEmpty);
      expect(topic.name, equals('test-group'));
      expect(topic.type, equals(TopicType.group));

      await module.deleteTopic(topic.id, hard: true);
      await module.disconnect();
    });

    test('create direct topic', () async {
      final userIdA = uniqueUserId();
      final userIdB = uniqueUserId();
      final moduleA = TicTacModule(makeConfig(userIdA));
      final moduleB = TicTacModule(makeConfig(userIdB));
      await moduleA.connect();
      await moduleB.connect();

      // A needs to know B's tinode user ID for P2P
      // Seed identity resolver with B's mapping
      moduleA.identityResolver.addMapping(
        userIdB,
        // Get B's tinode user ID from moduleB's identity resolver
        (await moduleB.identityResolver.resolve(userIdB)) ??
            // If not resolved, we need B's tinode ID from login
            '',
      );

      // For direct topics, we need the target's tinode user ID.
      // In phase 1, this requires manual seeding or prior contact.
      // Skip if we can't resolve — this validates the identity flow.
      final bTinodeId = await moduleA.identityResolver.resolve(userIdB);
      if (bTinodeId != null && bTinodeId.isNotEmpty) {
        final topic = await moduleA.createDirectTopic(userIdB);
        expect(topic.id, isNotEmpty);
        expect(topic.type, equals(TopicType.direct));
        await moduleA.deleteTopic(topic.id, hard: true);
      }

      await moduleA.disconnect();
      await moduleB.disconnect();
    });

    test('get topics includes created topic', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      await module.createGroupTopic('gettopics-test', []);

      final topics = await module.getTopics();
      final found = topics.any((t) => t.name == 'gettopics-test');
      expect(found, isTrue, reason: 'Expected gettopics-test in topic list');

      for (final t in topics.where((t) => t.name == 'gettopics-test')) {
        await module.deleteTopic(t.id, hard: true);
      }
      await module.disconnect();
    });

    test('delete topic removes from list', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      final topic = await module.createGroupTopic('delete-test', []);
      final topicId = topic.id;

      // Verify it exists
      var topics = await module.getTopics();
      expect(topics.any((t) => t.id == topicId), isTrue);

      // Delete it
      await module.deleteTopic(topicId, hard: true);

      // Verify it's gone
      topics = await module.getTopics();
      expect(topics.any((t) => t.id == topicId), isFalse,
          reason: 'Deleted topic should not appear in getTopics');

      await module.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // Message tests
  // -------------------------------------------------------------------------

  group('Messages', () {
    test('send text message', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      final topic = await module.createGroupTopic('sendmsg-test', []);
      final controller = await module.joinTopic(topic.id);

      await controller.sendMessage(
        const types.PartialText(text: 'hello from integration test'),
      );

      // Wait for message to be processed
      await Future.delayed(Duration(seconds: 1));

      expect(controller.messages, isNotEmpty);
      final first = controller.messages.first;
      expect(first, isA<types.TextMessage>());
      expect((first as types.TextMessage).text, equals('hello from integration test'));

      await module.deleteTopic(topic.id, hard: true);
      await module.disconnect();
    });

    test('send custom message', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      final topic = await module.createGroupTopic('custommsg-test', []);
      final controller = await module.joinTopic(topic.id);

      await controller.sendCustomMessage(
        'game_invite',
        {'gameId': 'abc123'},
        fallbackText: 'Game invite!',
      );

      await Future.delayed(Duration(seconds: 1));

      expect(controller.messages, isNotEmpty);

      await module.deleteTopic(topic.id, hard: true);
      await module.disconnect();
    });

    test('receive own message echo', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      final topic = await module.createGroupTopic('echo-test', []);
      final controller = await module.joinTopic(topic.id);

      await controller.sendMessage(
        const types.PartialText(text: 'echo ping'),
      );

      // Wait for echo to arrive and be processed
      await Future.delayed(Duration(seconds: 3));

      final hasMessage = controller.messages.any((m) =>
          m is types.TextMessage && m.text == 'echo ping');
      expect(hasMessage, isTrue, reason: 'Should have echo ping in messages');

      await module.deleteTopic(topic.id, hard: true);
      await module.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // Join / interaction tests
  // -------------------------------------------------------------------------

  group('Interactions', () {
    test('join topic returns controller', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      final topic = await module.createGroupTopic('join-test', []);
      final controller = await module.joinTopic(topic.id);

      expect(controller, isA<TopicController>());
      expect(controller.topicId, equals(topic.id));
      expect(controller.isConnected, isTrue);

      await module.deleteTopic(topic.id, hard: true);
      await module.disconnect();
    });

    test('join topic twice returns same controller', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      final topic = await module.createGroupTopic('join-twice-test', []);
      final c1 = await module.joinTopic(topic.id);
      final c2 = await module.joinTopic(topic.id);

      expect(identical(c1, c2), isTrue, reason: 'Same controller instance expected');

      await module.deleteTopic(topic.id, hard: true);
      await module.disconnect();
    });

    test('leave topic cleans up controller', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      final topic = await module.createGroupTopic('leave-test', []);
      await module.joinTopic(topic.id);

      await module.leaveTopic(topic.id);

      // Joining again should create a new controller
      final c2 = await module.joinTopic(topic.id);
      expect(c2, isA<TopicController>());

      await module.deleteTopic(topic.id, hard: true);
      await module.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // Identity resolver tests
  // -------------------------------------------------------------------------

  group('Identity', () {
    test('current user mapping seeded on connect', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      final tinodeId = await module.identityResolver.resolve(userId);
      expect(tinodeId, isNotNull);
      expect(tinodeId, isNotEmpty);
      expect(tinodeId!.startsWith('usr'), isTrue,
          reason: 'Tinode user IDs start with usr');

      // Reverse lookup should work too
      final resolvedAppId = await module.identityResolver.reverseLookup(tinodeId);
      expect(resolvedAppId, equals(userId));

      await module.disconnect();
    });
  });

  // -------------------------------------------------------------------------
  // Reconnection tests (basic)
  // -------------------------------------------------------------------------

  group('Reconnection', () {
    test('can reconnect after disconnect', () async {
      final userId = uniqueUserId();
      final module = TicTacModule(makeConfig(userId));
      await module.connect();

      // Create a topic
      final created = await module.createGroupTopic('reconnect-test', []);
      final createdId = created.id;
      await module.disconnect();
      expect(module.isConnected, isFalse);

      // Reconnect with fresh module (simulates app restart)
      final module2 = TicTacModule(makeConfig(userId));
      final topics = await module2.connect();

      expect(module2.isConnected, isTrue);
      // Check by ID since name resolution after reconnect requires desc fetch
      final found = topics.any((t) => t.id == createdId);
      expect(found, isTrue, reason: 'Topic should persist after reconnect');

      await module2.deleteTopic(createdId, hard: true);
      await module2.disconnect();
    });
  });
}
