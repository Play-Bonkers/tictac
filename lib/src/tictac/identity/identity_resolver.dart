/// Maps between app-level user IDs and Tinode-internal user IDs.
///
/// [CachedIdentityResolver] uses a local bidirectional cache
/// seeded from auth responses and topic membership.
///
/// [TagsIdentityResolver] calls TAILS via TAGS REST API for
/// batch lookup/reverse_lookup operations, with local cache.
abstract class IdentityResolver {
  /// Look up a tinode_user_id from an app_user_id.
  /// Returns null if the mapping is unknown.
  Future<String?> lookup(String appUserId);

  /// Look up an app_user_id from a tinode_user_id.
  /// Returns null if the mapping is unknown.
  Future<String?> reverseLookup(String tinodeUserId);

  /// Batch look up multiple app_user_ids to tinode_user_ids.
  /// Returns a map of app_user_id -> tinode_user_id (missing entries omitted).
  Future<Map<String, String>> batchLookup(List<String> appUserIds);

  /// Batch reverse look up multiple tinode_user_ids to app_user_ids.
  /// Returns a map of tinode_user_id -> app_user_id (missing entries omitted).
  Future<Map<String, String>> batchReverseLookup(List<String> tinodeUserIds);

  /// Seed a known mapping (e.g. from login response or topic membership).
  void addMapping(String appUserId, String tinodeUserId);
}
