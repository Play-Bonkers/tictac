import 'identity_resolver.dart';

/// Identity resolver that uses an in-memory bidirectional cache.
///
/// Seeded from:
/// - Login response (current user's app_user_id <-> tinode_user_id)
/// - Topic membership metadata (if public.appUserId is set)
class CachedIdentityResolver implements IdentityResolver {
  /// app_user_id -> tinode_user_id
  final Map<String, String> _forward = {};

  /// tinode_user_id -> app_user_id
  final Map<String, String> _reverse = {};

  @override
  void addMapping(String appUserId, String tinodeUserId) {
    _forward[appUserId] = tinodeUserId;
    _reverse[tinodeUserId] = appUserId;
  }

  @override
  Future<String?> lookup(String appUserId) async {
    return _forward[appUserId];
  }

  @override
  Future<String?> reverseLookup(String tinodeUserId) async {
    return _reverse[tinodeUserId];
  }

  @override
  Future<Map<String, String>> batchLookup(List<String> appUserIds) async {
    final result = <String, String>{};
    for (final id in appUserIds) {
      final tinodeId = _forward[id];
      if (tinodeId != null) {
        result[id] = tinodeId;
      }
    }
    return result;
  }

  @override
  Future<Map<String, String>> batchReverseLookup(List<String> tinodeUserIds) async {
    final result = <String, String>{};
    for (final id in tinodeUserIds) {
      final appId = _reverse[id];
      if (appId != null) {
        result[id] = appId;
      }
    }
    return result;
  }
}
