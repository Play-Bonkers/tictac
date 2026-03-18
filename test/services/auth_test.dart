import 'package:test/test.dart';

import 'package:tictac/src/models/auth-token.dart';
import 'package:tictac/src/models/server-messages.dart';
import 'package:tictac/src/services/auth.dart';

void main() {
  var service = AuthService();

  test('setLastLogin() should set last login', () {
    service.setLastLogin('test');
    expect(service.lastLogin, equals('test'));
  });

  test('setAuthToken() should set auth token', () {
    service.setAuthToken(AuthToken('token', DateTime.now()));
    expect(service.authToken?.token, equals('token'));
  });

  test('setUserId() should set userId', () {
    service.setUserId('test');
    expect(service.userId, equals('test'));
  });

  test('onLoginSuccessful() should set userId', () {
    var expireDate = DateTime.now();
    service.onLoginSuccessful(CtrlMessage(
      code: 200,
      params: {
        'user': 'userTest',
        'token': 'tokenTest',
        'expires': expireDate.toIso8601String(),
      },
    ));
    expect(service.userId, equals('userTest'));
    expect(service.authToken?.token, equals('tokenTest'));
    expect(service.authToken?.expires, equals(expireDate));
  });
}
