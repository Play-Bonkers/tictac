import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_test/flutter_test.dart';
import 'package:tictac/tictac.dart';

import 'support/harness.dart';

/// Reconnect-focused integration tests — verify the module recovers from
/// disconnects and that subscriptions / topic state survive the round trip.
///
/// Run: `dart test test/integration/reconnect_test.dart --timeout 120s`
void main() {
  group('Reconnect', () {
    test('module.reconnect() re-fires onConnected', () async {
      final h = Harness.boot();
      await h.module.connect();
      await h.awaitConnected();

      h.resetConnected();
      h.module.reconnect();

      final topics = await h.awaitConnected(
        timeout: const Duration(seconds: 20),
      );
      expect(topics, isA<List<Topic>>());
      expect(h.module.isConnected, isTrue);

      await h.dispose();
    });

    test('topics created before reconnect are still visible after', () async {
      final h = Harness.boot();
      await h.module.connect();
      await h.awaitConnected();

      final created = await h.module.createGroupTopic('reconnect-survives', []);
      expect(created.id, isNotEmpty);

      h.resetConnected();
      h.module.reconnect();
      final topics = await h.awaitConnected(
        timeout: const Duration(seconds: 20),
      );

      expect(topics.any((t) => t.id == created.id), isTrue,
          reason: 'topic created before reconnect should appear after');

      await h.module.deleteTopic(created.id, hard: true);
      await h.dispose();
    });

    test('active topic survives reconnect: send works after re-fire', () async {
      final h = Harness.boot();
      await h.module.connect();
      await h.awaitConnected();

      final topic = await h.module.createGroupTopic('reconnect-active', []);
      final handle = await h.module.joinTopic(topic.id);

      // Pre-reconnect send to prime the topic.
      await handle.sendText('before reconnect');
      await h.awaitMessage(
        topicId: topic.id,
        predicate: (m) =>
            m is types.TextMessage && m.text == 'before reconnect',
      );

      h.resetConnected();
      h.clearMessages();
      h.module.reconnect();
      await h.awaitConnected(timeout: const Duration(seconds: 20));

      // Re-acquire the handle. _reattachActiveTopics in the module
      // re-subscribes under the hood; joinTopic should resolve to the
      // re-attached subscription.
      final handle2 = await h.module.joinTopic(topic.id);

      await handle2.sendText('after reconnect');
      final echo = await h.awaitMessage(
        topicId: topic.id,
        predicate: (m) =>
            m is types.TextMessage && m.text == 'after reconnect',
        timeout: const Duration(seconds: 15),
      );
      expect(echo, isA<types.TextMessage>());

      await h.module.deleteTopic(topic.id, hard: true);
      await h.dispose();
    });

    test('second TicTacModule with same appUserId reuses Tinode account',
        () async {
      // Simulates an app cold start: dispose the module, recreate it with
      // the same appUserId, expect to see the previously-created topics.
      // Hits the cached-token path on the second connect.
      final userId = Harness.uniqueUserId();
      final h1 = Harness.bootWithUserId(userId);
      await h1.module.connect();
      await h1.awaitConnected();

      final created = await h1.module.createGroupTopic('cold-restart', []);
      await h1.module.disconnect();

      final h2 = Harness.bootWithUserId(userId);
      await h2.module.connect();
      final topics = await h2.awaitConnected();
      expect(topics.any((t) => t.id == created.id), isTrue,
          reason: 'cold-restart should see prior topics for the same user');

      await h2.module.deleteTopic(created.id, hard: true);
      await h2.dispose();
    });
  });
}
