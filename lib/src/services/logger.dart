import 'package:tictac/src/services/configuration.dart';

class LoggerService {
  late ConfigService _configService;

  LoggerService.withConfig(this._configService);

  void error(String value) {
    if (_configService.loggerEnabled == true) {
      print('ERROR: ' + value);
    }
  }

  void log(String value) {
    if (_configService.loggerEnabled == true) {
      print('LOG: ' + value);
    }
  }

  void warn(String value) {
    if (_configService.loggerEnabled == true) {
      print('WARN: ' + value);
    }
  }
}
