import 'package:test/test.dart';

import 'package:tictac/src/models/topic-subscription.dart';
import 'package:tictac/src/services/cache-manager.dart';
import 'package:tictac/src/models/connection-options.dart';
import 'package:tictac/src/services/services.dart';
import 'package:tictac/src/topic.dart';

void main() {
  var services = TinodeServices(ConnectionOptions('', ''), false);
  var service = CacheManager();

  test('put() should put data into cache', () {
    service.put('type', 'test', {'name': 'hello'});
    expect(service.get('type', 'test')['name'], 'hello');
  });

  test('putUser() should put user type data into cache', () {
    service.putUser('test', TopicSubscription(online: true));
    expect(service.get('user', 'test').online, true);
  });

  test('getUser() should return user type data from cache', () {
    service.putUser('test', TopicSubscription(online: true));
    expect(service.getUser('test')?.online, true);
  });

  test('deleteUser() should delete user type data from cache', () {
    service.putUser('test', TopicSubscription(online: true));
    expect(service.getUser('test')?.online, true);
    service.deleteUser('test');
    expect(service.getUser('test'), null);
  });

  test('putTopic() should put topic type data into cache', () {
    var t = Topic('cool', services: services);
    t.seq = 100;
    service.putTopic(t);
    expect(service.get('topic', 'cool').seq, 100);
  });

  test('deleteTopic() should delete topic type data from cache', () {
    var t = Topic('cool', services: services);
    t.seq = 100;
    service.putTopic(t);
    expect(service.get('topic', 'cool').seq, 100);
    service.deleteTopic('cool');
    expect(service.get('topic', 'cool'), null);
  });

  test('delete() should delete data from cache', () {
    service.put('type', 'test', {'name': 'hello'});
    expect(service.get('type', 'test')['name'], 'hello');
    service.delete('type', 'test');
    expect(service.get('type', 'test'), null);
  });

  test('map() should execute a function for all values in cache', () {
    var t = Topic('cool', services: services);
    t.isSubscribed = true;
    service.putTopic(t);
    service.map((String key, dynamic value) {
      if (key.contains('topic:')) {
        Topic topic = value;
        topic.resetSubscription();
      }
      return MapEntry(key, value);
    });
    expect(service.get('topic', 'cool').isSubscribed, false);
  });
}
