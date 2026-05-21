import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_test/flutter_test.dart';
import 'package:tictac/tictac.dart';

import 'support/harness.dart';

/// v3 integration tests — exercise the public callback-based API against
/// a live Tinode dev server.
///
/// Run: `dart test test/integration/tictac_integration_test.dart --timeout 120s`
///
/// Each test fabricates a fresh app-user-id and relies on `provision: true`
/// so the REST auth Lambda mints a brand-new Tinode account. No prior
/// state is required.
void main() {
  group('Session', () {
    test('connect fires onConnected with topic list', () async {
      final h = Harness.boot();
      await h.module.connect();

      final topics = await h.awaitConnected();
      expect(topics, isA<List<Topic>>());
      expect(h.module.isConnected, isTrue);

      await h.dispose();
    });

    test('intentional disconnect leaves module disconnected', () async {
      final h = Harness.boot();
      await h.module.connect();
      await h.awaitConnected();
      expect(h.module.isConnected, isTrue);

      await h.module.disconnect();
      expect(h.module.isConnected, isFalse);
    });
  });

  group('Topics', () {
    test('create group topic shows up in refreshTopics', () async {
      final h = Harness.boot();
      await h.module.connect();
      await h.awaitConnected();

      final created = await h.module.createGroupTopic('group-create', []);
      expect(created.id, isNotEmpty);
      expect(created.type, TopicType.group);

      final fresh = await h.module.refreshTopics();
      expect(fresh.any((t) => t.id == created.id), isTrue,
          reason: 'newly created topic should appear in refreshTopics');

      await h.module.deleteTopic(created.id, hard: true);
      await h.dispose();
    });

    test('deleteTopic removes the topic from refreshTopics', () async {
      final h = Harness.boot();
      await h.module.connect();
      await h.awaitConnected();

      final created = await h.module.createGroupTopic('group-delete', []);
      await h.module.deleteTopic(created.id, hard: true);

      final fresh = await h.module.refreshTopics();
      expect(fresh.any((t) => t.id == created.id), isFalse,
          reason: 'deleted topic should not appear in refreshTopics');

      await h.dispose();
    });
  });

  group('Messages', () {
    test('sendText surfaces an echo via onMessageReceived', () async {
      final h = Harness.boot();
      await h.module.connect();
      await h.awaitConnected();

      final topic = await h.module.createGroupTopic('msg-text-echo', []);
      final handle = await h.module.joinTopic(topic.id);

      await handle.sendText('hello round-trip');

      final msg = await h.awaitMessage(
        topicId: topic.id,
        predicate: (m) => m is types.TextMessage && m.text == 'hello round-trip',
      );
      expect(msg, isA<types.TextMessage>());
      expect((msg as types.TextMessage).text, equals('hello round-trip'));

      await h.module.deleteTopic(topic.id, hard: true);
      await h.dispose();
    });

    test('sendCustom round-trips with metadata intact', () async {
      final h = Harness.boot();
      await h.module.connect();
      await h.awaitConnected();

      final topic = await h.module.createGroupTopic('msg-custom-echo', []);
      final handle = await h.module.joinTopic(topic.id);

      await handle.sendCustom(
        'game_invite',
        {'gameId': 'chess-123', 'gameName': 'Chess'},
        fallbackText: 'Game invite!',
      );

      final msg = await h.awaitMessage(
        topicId: topic.id,
        predicate: (m) =>
            m is types.CustomMessage &&
            m.metadata?['customType'] == 'game_invite',
      );
      final custom = msg as types.CustomMessage;
      final payload = custom.metadata?['payload'] as Map?;
      expect(payload?['gameId'], 'chess-123');
      expect(payload?['gameName'], 'Chess');
      expect(custom.metadata?['fallbackText'], 'Game invite!');

      await h.module.deleteTopic(topic.id, hard: true);
      await h.dispose();
    });

    test('deleteMessage removes the message server-side', () async {
      final h = Harness.boot();
      await h.module.connect();
      await h.awaitConnected();

      final topic = await h.module.createGroupTopic('msg-delete', []);
      final handle = await h.module.joinTopic(topic.id);

      await handle.sendText('to be deleted');
      final received = await h.awaitMessage(
        topicId: topic.id,
        predicate: (m) =>
            m is types.TextMessage && m.text == 'to be deleted',
      );

      await handle.deleteMessage(received.id);

      // Rejoin to force a fresh fetch from server.
      await handle.leave();
      h.clearMessages();
      final handle2 = await h.module.joinTopic(topic.id);

      // Give the server a beat to replay history.
      await Future<void>.delayed(const Duration(seconds: 2));
      final stillPresent = h.allMessages.any((entry) =>
          entry.message is types.TextMessage &&
          (entry.message as types.TextMessage).text == 'to be deleted');
      expect(stillPresent, isFalse,
          reason: 'deleted message should not reappear on rejoin');

      await handle2.leave();
      await h.module.deleteTopic(topic.id, hard: true);
      await h.dispose();
    });
  });

  group('Join', () {
    test('joinTopic returns a handle for the same id twice', () async {
      final h = Harness.boot();
      await h.module.connect();
      await h.awaitConnected();

      final topic = await h.module.createGroupTopic('join-twice', []);
      final h1 = await h.module.joinTopic(topic.id);
      final h2 = await h.module.joinTopic(topic.id);
      expect(h1.topicId, h2.topicId);

      await h.module.deleteTopic(topic.id, hard: true);
      await h.dispose();
    });
  });

  group('Read receipts', () {
    test('peer markRead surfaces onMessageRead to the sender', () async {
      // Two users, two views of one P2P topic. A sends, B reads, A is told.
      final a = Harness.boot();
      final b = Harness.boot();
      await a.module.connect();
      await b.module.connect();
      await a.awaitConnected();
      await b.awaitConnected();

      final uidA = a.module.tinodeUserId;
      final uidB = b.module.tinodeUserId;
      expect(uidA, isNotNull, reason: 'A must expose its tinode uid');
      expect(uidB, isNotNull, reason: 'B must expose its tinode uid');

      // Each side names the OTHER user's tinode uid — same underlying P2P.
      final topicA = await a.module.createDirectTopic(uidB!);
      final topicB = await b.module.createDirectTopic(uidA!);

      final handleA = await a.module.joinTopic(topicA.id);
      final handleB = await b.module.joinTopic(topicB.id);

      // A sends; A sees its own server echo (message id == seq).
      await handleA.sendText('read-receipt probe');
      final echo = await a.awaitMessage(
        topicId: topicA.id,
        predicate: (m) =>
            m is types.TextMessage && m.text == 'read-receipt probe',
      );
      final echoSeq = int.parse(echo.id);

      // B receives the same message on its view of the topic.
      final onB = await b.awaitMessage(
        topicId: topicB.id,
        predicate: (m) =>
            m is types.TextMessage && m.text == 'read-receipt probe',
      );

      // B marks it read -> A must receive onMessageRead covering that seq.
      await handleB.markRead(onB.id);

      final read = await a.awaitRead(
        topicId: topicA.id,
        predicate: (r) => r.seq >= echoSeq,
      );
      expect(read.seq, greaterThanOrEqualTo(echoSeq));
      expect(read.appUserId, isNotEmpty,
          reason: 'read receipt should identify the peer');

      await a.module.deleteTopic(topicA.id, hard: true);
      await a.dispose();
      await b.dispose();
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
