import 'package:tictac/src/models/connection-options.dart';
import 'package:tictac/src/services/packet-generator.dart';
import 'package:tictac/src/services/future-manager.dart';
import 'package:tictac/src/services/cache-manager.dart';
import 'package:tictac/src/services/configuration.dart';
import 'package:tictac/src/services/connection.dart';
import 'package:tictac/src/services/logger.dart';
import 'package:tictac/src/services/tinode.dart';
import 'package:tictac/src/services/auth.dart';

/// Dependency container holding all services for a single Tinode instance.
/// Replaces GetIt singletons so multiple Tinode instances can coexist.
class TinodeServices {
  late final ConfigService config;
  late final LoggerService logger;
  late final AuthService auth;
  late final ConnectionService connection;
  late final FutureManager futureManager;
  late final PacketGenerator packetGenerator;
  late final CacheManager cacheManager;
  late final TinodeService tinode;

  TinodeServices(ConnectionOptions options, bool loggerEnabled) {
    config = ConfigService(loggerEnabled);
    logger = LoggerService.withConfig(config);
    auth = AuthService();
    connection = ConnectionService.withLogger(options, logger);
    futureManager = FutureManager.withServices(config, logger);
    packetGenerator = PacketGenerator.withConfig(config);
    cacheManager = CacheManager();
    tinode = TinodeService.withServices(this);
  }
}
