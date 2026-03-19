import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tictac/tinode.dart';
import 'package:tictac/src/models/rest-auth-secret.dart';

/// Smoke tests against a live Tinode server.
/// Run with: dart test test/smoke/tinode_smoke_test.dart
///
/// Environment variables (compile-time):
///   TINODE_HOST  - Tinode host:port (default: 44.234.36.7:6060)
///   TINODE_KEY   - API key (default: AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K)
void main() {
  final host = const String.fromEnvironment('TINODE_HOST',
      defaultValue: '44.234.36.7:6060');
  final apiKey = const String.fromEnvironment('TINODE_KEY',
      defaultValue: 'AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K');

  // TAILS integration test app credentials
  const testAppId = 'd9c3780a-8be6-4d7c-8572-3272e985a415';
  const testAppKey = 'x8eKwfsOHH_hTXNSdTUhEMmBlJ9QB4g34zdg2k8IuFI';

  /// Build the protobuf-encoded REST auth secret that Tinode's REST auth
  /// plugin expects (matches TAILS RestAuthSecret proto).
  String makeRestSecret(String appUserId) {
    final secret = RestAuthSecret(
      appUserId: appUserId,
      appId: testAppId,
      appKey: testAppKey,
    );
    return base64.encode(secret.toBytes());
  }

  Tinode makeTinode() {
    return Tinode(
        'TicTac-Smoke/1.0', ConnectionOptions(host, apiKey), true);
  }

  test('connect to Tinode server', () async {
    var tinode = makeTinode();
    await tinode.connect();
    expect(tinode.isConnected, isTrue);
    // Don't call disconnect() — it has a null cast bug we'll fix later
  });

  test('login with REST auth (protobuf secret)', () async {
    var tinode = makeTinode();
    await tinode.connect();
    expect(tinode.isConnected, isTrue);

    var secret = makeRestSecret('smoke-test-user-001');
    var ctrl = await tinode.login('rest', secret, null);
    expect(ctrl.code, equals(200));
    expect(tinode.isAuthenticated, isTrue);
    expect(tinode.userId, isNotEmpty);
    print('Logged in as tinode user: ${tinode.userId}');

    // Verify token was returned
    var token = tinode.getAuthenticationToken();
    expect(token, isNotNull);
    expect(token!.token, isNotEmpty);
    print('Token expires: ${token.expires}');
  });

  test('token is valid for reuse', () async {
    var tinode = makeTinode();
    await tinode.connect();

    var secret = makeRestSecret('smoke-test-user-002');
    await tinode.login('rest', secret, null);
    var token = tinode.getAuthenticationToken()!;

    expect(token.token, isNotEmpty);
    expect(token.expires.isAfter(DateTime.now()), isTrue);
    print('Token valid until: ${token.expires}');
  });

  test('subscribe to me topic', () async {
    var tinode = makeTinode();
    await tinode.connect();

    var secret = makeRestSecret('smoke-test-user-003');
    await tinode.login('rest', secret, null);

    // Subscribe to 'me' topic — this is the exact flow that times out in CXS
    var me = tinode.getMeTopic();
    await me.subscribe(
        MetaGetBuilder(me).withLaterSub(null).build(), null);
    expect(me.isSubscribed, isTrue);
    print('Subscribed to "me" topic successfully');
  });

  test('create group topic and send message', () async {
    var tinode = makeTinode();
    await tinode.connect();

    var secret = makeRestSecret('smoke-test-user-004');
    await tinode.login('rest', secret, null);

    // Subscribe to 'me' first
    var me = tinode.getMeTopic();
    await me.subscribe(
        MetaGetBuilder(me).withLaterSub(null).build(), null);

    // Create a new group topic
    var newTopic = tinode.newTopic();
    var setParams = SetParams();
    setParams.desc = TopicDescription();
    setParams.desc!.public = {'fn': 'Smoke Test Group'};

    await newTopic.subscribe(MetaGetBuilder(newTopic).build(), setParams);
    expect(newTopic.name, isNotEmpty);
    expect(newTopic.isSubscribed, isTrue);
    print('Created topic: ${newTopic.name}');

    // Send a message
    var msg = newTopic.createMessage('Hello from smoke test!', true);
    await newTopic.publishMessage(msg);
    print('Message sent successfully');

    // Clean up
    await newTopic.deleteTopic(true);
    print('Topic deleted');
  });

  test('send message and receive echo', () async {
    var tinode = makeTinode();
    await tinode.connect();

    var secret = makeRestSecret('smoke-test-user-005');
    await tinode.login('rest', secret, null);

    var me = tinode.getMeTopic();
    await me.subscribe(
        MetaGetBuilder(me).withLaterSub(null).build(), null);

    // Create group topic
    var grp = tinode.newTopic();
    var setParams = SetParams();
    setParams.desc = TopicDescription();
    setParams.desc!.public = {'fn': 'Echo Test'};

    await grp.subscribe(MetaGetBuilder(grp).build(), setParams);

    var received = false;
    grp.onData.listen((value) {
      if (value != null && value.content == 'ping from smoke test') {
        received = true;
      }
    });

    var msg = grp.createMessage('ping from smoke test', true);
    await grp.publishMessage(msg);

    // Give time for the echo
    await Future.delayed(Duration(seconds: 2));
    expect(received, isTrue, reason: 'Should receive own message echo');
    print('Echo received successfully');

    await grp.deleteTopic(true);
  });
}
