import 'dart:async';

import 'package:tictac/src/models/future-callback.dart';
import 'package:tictac/src/services/configuration.dart';
import 'package:tictac/src/services/logger.dart';

class FutureManager {
  final Map<String, FutureCallback> _pendingFutures = {};
  Timer? _expiredFuturesCheckerTimer;
  late ConfigService _configService;
  late LoggerService _loggerService;

  FutureManager.withServices(this._configService, this._loggerService);

  Future<dynamic> makeFuture(String id) {
    var completer = Completer();
    if (id != null) {
      _pendingFutures[id] = FutureCallback(completer: completer, ts: DateTime.now());
    }
    return completer.future;
  }

  void execFuture(String? id, int code, dynamic onOK, String? errorText) {
    var callbacks = _pendingFutures[id];

    if (callbacks != null) {
      _pendingFutures.remove(id);
      final c = callbacks.completer;
      if (c == null || c.isCompleted) return;
      if (code >= 200 && code < 400) {
        c.complete(onOK);
      } else {
        c.completeError(
          Exception((errorText ?? '') + ' (' + code.toString() + ')'),
        );
      }
    }
  }

  void checkExpiredFutures() {
    var exception = Exception('Timeout (504)');
    var expires = DateTime.now().subtract(Duration(milliseconds: _configService.appSettings.expireFuturesTimeout));

    var markForRemoval = <String>[];
    _pendingFutures.forEach((String key, FutureCallback featureCB) {
      if (featureCB.ts!.isBefore(expires)) {
        _loggerService.error('Promise expired ' + key.toString());
        final c = featureCB.completer;
        if (c != null && !c.isCompleted) {
          c.completeError(exception);
        }
        markForRemoval.add(key);
      }
    });

    _pendingFutures.removeWhere((key, value) => markForRemoval.contains(key));
  }

  void startCheckingExpiredFutures() {
    if (_expiredFuturesCheckerTimer != null && _expiredFuturesCheckerTimer!.isActive) {
      return;
    }
    _expiredFuturesCheckerTimer = Timer.periodic(Duration(milliseconds: _configService.appSettings.expireFuturesPeriod), (_) {
      checkExpiredFutures();
    });
  }

  void rejectAllFutures(int code, String reason) {
    // Guard each completer against being already-resolved (execFuture
    // could have raced this on a different microtask, or a prior
    // rejectAllFutures call could have completed it). Clear the map
    // afterwards so a second disconnect doesn't re-walk the same
    // entries and trip the same race.
    for (final cb in _pendingFutures.values) {
      final c = cb.completer;
      if (c != null && !c.isCompleted) {
        c.completeError(reason);
      }
    }
    _pendingFutures.clear();
  }

  void stopCheckingExpiredFutures() {
    if (_expiredFuturesCheckerTimer != null) {
      _expiredFuturesCheckerTimer?.cancel();
      _expiredFuturesCheckerTimer = null;
    }
  }
}
