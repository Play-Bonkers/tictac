import 'package:rxdart/rxdart.dart';
import 'dart:io';

import 'package:tictac/src/models/connection-options.dart';
import 'package:tictac/src/services/logger.dart';
import 'package:tictac/src/services/tools.dart';

import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/io.dart';

/// This class is responsible for `ws` connection establishments
///
/// Supports `ws` and `wss`
class ConnectionService {
  /// Connection configuration options provided by library user
  final ConnectionOptions _options;

  /// Websocket wrapper channel based on `dart:io`
  IOWebSocketChannel? _channel;

  /// Websocket connection
  WebSocket? _ws;

  /// This callback will be called when connection is opened
  PublishSubject<dynamic> onOpen = PublishSubject<dynamic>();

  /// This callback will be called when connection is closed
  PublishSubject<void> onDisconnect = PublishSubject<void>();

  /// This callback will be called when we receive a message from server
  PublishSubject<String> onMessage = PublishSubject<String>();

  late LoggerService _loggerService;

  bool _connecting = false;

  ConnectionService.withLogger(this._options, this._loggerService);

  bool get isConnected {
    return _ws != null && _ws?.readyState == WebSocket.open;
  }

  /// Start opening websocket connection
  Future connect() async {
    _loggerService.log('Connecting to ' + Tools.makeBaseURL(_options));
    if (isConnected) {
      _loggerService.warn('Reconnecting...');
    }
    _connecting = true;
    _ws = await WebSocket.connect(Tools.makeBaseURL(_options)).timeout(Duration(milliseconds: 5000));
    _connecting = false;
    _loggerService.log('Connected.');
    _channel = IOWebSocketChannel(_ws!);
    onOpen.add('Opened');
    _channel!.stream.listen(
      (message) { onMessage.add(message); },
      onDone: () { onDisconnect.add(null); },
      onError: (_) { onDisconnect.add(null); },
    );
  }

  /// Send a message through websocket websocket connection
  void sendText(String str) {
    if (!isConnected || _connecting) {
      throw Exception('Tried sending data but you are not connected yet.');
    }
    _channel!.sink.add(str);
  }

  /// Close current websocket connection
  void disconnect() {
    _channel = null;
    _connecting = false;
    _ws?.close(status.goingAway);
    onDisconnect.add(null);
  }

  /// Send network probe to check if connection is indeed live
  void probe() {
    return sendText('1');
  }
}
