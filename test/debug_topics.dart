import 'package:tictac/tictac.dart';
import 'package:tictac/tinode.dart' as tinode;

void main() async {
  final config = TicTacConfig(
    tinodeHost: '44.234.36.7',
    tinodePort: 6060,
    appUserId: 'debug-user-001',
    appId: 'd9c3780a-8be6-4d7c-8572-3272e985a415',
    appKey: 'x8eKwfsOHH_hTXNSdTUhEMmBlJ9QB4g34zdg2k8IuFI',
    sessionId: 's1',
    generateRequestId: () => 'r1',
  );

  final module = TicTacModule(config);
  final connectTopics = await module.connect();
  print('CONNECT topics: ${connectTopics.length}');

  await module.createGroupTopic('debug-test-xyz', []);
  print('Created group topic');

  final topics = await module.getTopics();
  print('GET_TOPICS: ${topics.length}');
  for (final t in topics) {
    print('  id=${t.id} name=${t.name} type=${t.type}');
  }

  // Check what public field contains
  print('Topic details:');
  for (final t in topics) {
    print('  id=${t.id} name=${t.name} members=${t.memberAppUserIds}');
  }

  // Cleanup
  for (final t in topics.where((t) => t.name == 'debug-test-xyz')) {
    await module.deleteTopic(t.id, hard: true);
    print('Deleted ${t.id}');
  }
  await module.disconnect();
}
