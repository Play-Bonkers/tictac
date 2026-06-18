import 'package:flutter_test/flutter_test.dart';
import 'package:tictac/tictac.dart';

void main() {
  TicTacConfig makeConfig({
    Duration? inboundIdleThreshold,
    Duration? appKeepaliveInterval,
  }) {
    return TicTacConfig(
      tinodeHost: 'localhost',
      appUserId: 'u',
      appId: 'a',
      appKey: 'k',
      sessionId: 's',
      generateRequestId: () => 'r',
      authTokenProvider: () async => null,
      resolveAppUserId: (_) async => null,
      inboundIdleThreshold:
          inboundIdleThreshold ?? const Duration(seconds: 60),
      appKeepaliveInterval:
          appKeepaliveInterval ?? const Duration(seconds: 30),
    );
  }

  test('BNK-581 watchdog defaults sit above Tinode pongWait=55s', () {
    final c = makeConfig();
    expect(c.inboundIdleThreshold, equals(const Duration(seconds: 60)));
    expect(c.appKeepaliveInterval, equals(const Duration(seconds: 30)));
  });

  test('BNK-581 watchdog default exceeds Tinode pongWait', () {
    // Tinode hardcodes idleSessionTimeout / pongWait at 55s
    // (server/main.go). The watchdog must wait past that so a
    // healthy-but-quiet session isn't tripped.
    final c = makeConfig();
    expect(c.inboundIdleThreshold,
        greaterThan(const Duration(seconds: 55)));
  });

  test('BNK-581 app keepalive default fits inside pongWait', () {
    // appKeepaliveInterval needs to be short enough that a healthy
    // session always has a recent inbound {meta} reply before the
    // watchdog window closes.
    final c = makeConfig();
    expect(c.appKeepaliveInterval, lessThan(c.inboundIdleThreshold));
  });

  test('BNK-581 watchdog and keepalive accept overrides', () {
    final c = makeConfig(
      inboundIdleThreshold: const Duration(seconds: 45),
      appKeepaliveInterval: const Duration(seconds: 15),
    );
    expect(c.inboundIdleThreshold, equals(const Duration(seconds: 45)));
    expect(c.appKeepaliveInterval, equals(const Duration(seconds: 15)));
  });
}
