import 'package:rxdart/rxdart.dart';

import 'package:tictac/src/models/message-status.dart' as message_status;
import 'package:tictac/src/models/packet-types.dart' as packet_types;
import 'package:tictac/src/services/packet-generator.dart';
import 'package:tictac/src/models/server-messages.dart';
import 'package:tictac/src/models/packet-data.dart';
import 'package:tictac/src/models/packet.dart';

class Message {
  bool echo;
  int? _status;
  DateTime? ts;
  String? from;
  bool? cancelled;
  dynamic content;
  String? topicName;
  bool? noForwarding;

  late PacketGenerator _packetGenerator;

  PublishSubject<int> onStatusChange = PublishSubject<int>();

  Message(this.topicName, this.content, this.echo, {PacketGenerator? packetGenerator}) {
    _status = message_status.NONE;
    if (packetGenerator != null) {
      _packetGenerator = packetGenerator;
    }
  }

  Packet asPubPacket() {
    var packet = _packetGenerator.generate(packet_types.Pub, topicName);
    var data = packet.data as PubPacketData;
    data.content = content;
    data.noecho = !echo;
    packet.data = data;
    return packet;
  }

  DataMessage asDataMessage(String from, int seq) {
    return DataMessage(
      content: content,
      from: from,
      noForwarding: false,
      head: {},
      hi: null,
      topic: topicName,
      seq: seq,
      ts: ts,
    );
  }

  void setStatus(int status) {
    _status = status;
    onStatusChange.add(status);
  }

  int? getStatus() {
    return _status;
  }

  void resetLocalValues() {
    ts = null;
    setStatus(message_status.NONE);
  }
}
