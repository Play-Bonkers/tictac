/// Maps between app-level user IDs and Tinode-internal user IDs.
///
/// Phase 1: [CachedIdentityResolver] uses a local bidirectional cache
/// seeded from auth responses and topic membership.
///
/// Phase 2: [TagsIdentityResolver] will call TAILS via TAGS ALB for
/// batch resolve/reverse_lookup operations.
abstract class IdentityResolver {
  /// Map an app_user_id to a tinode_user_id.
  /// Returns null if the mapping is unknown.
  Future<String?> resolve(String appUserId);

  /// Map a tinode_user_id back to an app_user_id.
  /// Returns null if the mapping is unknown.
  Future<String?> reverseLookup(String tinodeUserId);

  /// Batch resolve multiple app_user_ids to tinode_user_ids.
  /// Returns a map of app_user_id -> tinode_user_id (missing entries omitted).
  Future<Map<String, String>> batchResolve(List<String> appUserIds);

  /// Batch reverse lookup multiple tinode_user_ids to app_user_ids.
  /// Returns a map of tinode_user_id -> app_user_id (missing entries omitted).
  Future<Map<String, String>> batchReverseLookup(List<String> tinodeUserIds);

  /// Seed a known mapping (e.g. from login response or topic membership).
  void addMapping(String appUserId, String tinodeUserId);
}
