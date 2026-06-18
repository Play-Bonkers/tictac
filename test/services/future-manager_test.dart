import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:tictac/src/services/configuration.dart';
import 'package:tictac/src/services/future-manager.dart';
import 'package:tictac/src/services/logger.dart';

void main() {
  FutureManager makeManager() {
    final config = ConfigService(false);
    final logger = LoggerService.withConfig(config);
    return FutureManager.withServices(config, logger);
  }

  test('rejectAllFutures completes pending futures with the reason', () async {
    final mgr = makeManager();
    final f = mgr.makeFuture('a');
    mgr.rejectAllFutures(500, 'gone');
    expectLater(f, throwsA('gone'));
  });

  test('rejectAllFutures called twice does not throw', () {
    final mgr = makeManager();
    // Attach handlers so the rejected futures don't surface as
    // unhandled zone errors during the test.
    mgr.makeFuture('a').catchError((_) {});
    mgr.makeFuture('b').catchError((_) {});
    mgr.rejectAllFutures(500, 'first');
    // A second disconnect (or any subsequent caller) used to trip
    // "Bad state: Future already completed" because the map wasn't
    // cleared and completers were re-walked. Must now be a no-op.
    expect(() => mgr.rejectAllFutures(500, 'second'), returnsNormally);
  });

  test('execFuture on a pending id resolves with the payload', () async {
    final mgr = makeManager();
    final f = mgr.makeFuture('a');
    mgr.execFuture('a', 200, 'ok', null);
    await expectLater(f, completion(equals('ok')));
  });

  test('execFuture after rejectAllFutures is a no-op', () {
    final mgr = makeManager();
    mgr.makeFuture('a').catchError((_) {});
    mgr.rejectAllFutures(500, 'gone');
    // Pending future for 'a' was rejected + the map was cleared. A
    // late ctrl arriving for the same id must not throw.
    expect(() => mgr.execFuture('a', 200, 'ok', null), returnsNormally);
  });

  test('BNK-637: rejection without explicit handler does not escape '
      'the zone', () async {
    // makeFuture now attaches an absorbing catchError listener; a
    // caller that never awaits / never attaches a handler must not
    // produce an unhandled error. Run inside a zone whose error
    // handler will fail the test if it sees anything.
    var leaked = false;
    await runZonedGuarded(() async {
      final mgr = makeManager();
      mgr.makeFuture('a'); // intentionally fire-and-forget
      mgr.rejectAllFutures(500, 'gone');
      // Give microtasks a turn to flush.
      await Future<void>.delayed(Duration.zero);
    }, (e, st) {
      leaked = true;
    });
    expect(leaked, isFalse,
        reason: 'awaiterless rejection must not surface to the zone');
  });

  test('BNK-637: legitimate awaiter still sees the rejection', () async {
    // The absorbing catchError must not consume the error for code
    // that does await the future. The await chain has its own
    // listener; the absorbing one is on a sibling side chain.
    final mgr = makeManager();
    final f = mgr.makeFuture('a');
    final caught = expectLater(f, throwsA(anything));
    mgr.rejectAllFutures(500, 'gone');
    await caught;
  });
}
