import 'dart:typed_data';

/// Encodes a RestAuthSecret protobuf message matching the TAILS proto definition:
///
///   message RestAuthSecret {
///     string app_user_id = 1;
///     string app_id = 2;
///     string app_key = 3;
///   }
///
/// Uses manual wire encoding to avoid depending on generated proto stubs.
class RestAuthSecret {
  final String appUserId;
  final String appId;
  final String appKey;

  RestAuthSecret({
    required this.appUserId,
    required this.appId,
    required this.appKey,
  });

  /// Encode to protobuf wire format bytes.
  List<int> toBytes() {
    final buffer = BytesBuilder();
    _writeString(buffer, 1, appUserId);
    _writeString(buffer, 2, appId);
    _writeString(buffer, 3, appKey);
    return buffer.toBytes();
  }

  /// Write a protobuf string field (wire type 2 = length-delimited).
  static void _writeString(BytesBuilder buffer, int fieldNumber, String value) {
    if (value.isEmpty) return;
    final bytes = Uint8List.fromList(value.codeUnits);
    // Tag: (fieldNumber << 3) | 2
    _writeVarint(buffer, (fieldNumber << 3) | 2);
    _writeVarint(buffer, bytes.length);
    buffer.add(bytes);
  }

  /// Write a varint (variable-length integer).
  static void _writeVarint(BytesBuilder buffer, int value) {
    while (value > 0x7F) {
      buffer.addByte((value & 0x7F) | 0x80);
      value >>= 7;
    }
    buffer.addByte(value & 0x7F);
  }
}
