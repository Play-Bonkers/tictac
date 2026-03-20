import 'dart:convert';
import 'dart:io';

import 'identity_resolver.dart';
import 'cached_identity_resolver.dart';

/// Identity resolver that calls TAGS REST API for lookups not in local cache.
///
/// Endpoints:
///   POST /identity/lookup          — batch app_user_id -> tinode_user_id
///   POST /identity/reverse-lookup  — batch tinode_user_id -> app_user_id
///
/// Auth: x-app-id + x-app-key headers (no Cognito JWT needed).
///
/// Falls back to local cache for known mappings to minimize network calls.
class TagsIdentityResolver implements IdentityResolver {
  final String tagsBaseUrl;
  final String appId;
  final String appKey;

  final CachedIdentityResolver _cache = CachedIdentityResolver();
  final HttpClient _httpClient = HttpClient();

  TagsIdentityResolver({
    required this.tagsBaseUrl,
    required this.appId,
    required this.appKey,
  }) {
    _httpClient.connectionTimeout = const Duration(seconds: 5);
  }

  @override
  void addMapping(String appUserId, String tinodeUserId) {
    _cache.addMapping(appUserId, tinodeUserId);
  }

  @override
  Future<String?> lookup(String appUserId) async {
    final cached = await _cache.lookup(appUserId);
    if (cached != null) return cached;

    final result = await batchLookup([appUserId]);
    return result[appUserId];
  }

  @override
  Future<String?> reverseLookup(String tinodeUserId) async {
    final cached = await _cache.reverseLookup(tinodeUserId);
    if (cached != null) return cached;

    final result = await batchReverseLookup([tinodeUserId]);
    return result[tinodeUserId];
  }

  @override
  Future<Map<String, String>> batchLookup(List<String> appUserIds) async {
    if (appUserIds.isEmpty) return {};

    final result = <String, String>{};
    final uncached = <String>[];

    for (final id in appUserIds) {
      final cached = await _cache.lookup(id);
      if (cached != null) {
        result[id] = cached;
      } else {
        uncached.add(id);
      }
    }

    if (uncached.isEmpty) return result;

    final response = await _post('/identity/lookup', {
      'app_user_ids': uncached,
    });

    if (response != null && response['mappings'] is Map) {
      final mappings = response['mappings'] as Map;
      for (final entry in mappings.entries) {
        final appUserId = entry.key.toString();
        final tinodeUserId = entry.value.toString();
        if (tinodeUserId.isNotEmpty) {
          _cache.addMapping(appUserId, tinodeUserId);
          result[appUserId] = tinodeUserId;
        }
      }
    }

    return result;
  }

  @override
  Future<Map<String, String>> batchReverseLookup(List<String> tinodeUserIds) async {
    if (tinodeUserIds.isEmpty) return {};

    final result = <String, String>{};
    final uncached = <String>[];

    for (final id in tinodeUserIds) {
      final cached = await _cache.reverseLookup(id);
      if (cached != null) {
        result[id] = cached;
      } else {
        uncached.add(id);
      }
    }

    if (uncached.isEmpty) return result;

    final response = await _post('/identity/reverse-lookup', {
      'service_user_ids': uncached,
    });

    if (response != null && response['mappings'] is Map) {
      final mappings = response['mappings'] as Map;
      for (final entry in mappings.entries) {
        final tinodeUserId = entry.key.toString();
        final appUserId = entry.value.toString();
        if (appUserId.isNotEmpty) {
          _cache.addMapping(appUserId, tinodeUserId);
          result[tinodeUserId] = appUserId;
        }
      }
    }

    return result;
  }

  Future<Map<String, dynamic>?> _post(String path, Map<String, dynamic> body) async {
    try {
      final uri = Uri.parse('$tagsBaseUrl$path');
      final request = await _httpClient.postUrl(uri);
      request.headers.set('content-type', 'application/json');
      request.headers.set('x-app-id', appId);
      request.headers.set('x-app-key', appKey);
      request.write(jsonEncode(body));

      final response = await request.close().timeout(const Duration(seconds: 10));
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        return jsonDecode(responseBody) as Map<String, dynamic>;
      }

      // ignore: avoid_print
      print('TicTac: TAGS $path failed: ${response.statusCode} $responseBody');
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('TicTac: TAGS $path error: $e');
      return null;
    }
  }
}
