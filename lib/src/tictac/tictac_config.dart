class TicTacConfig {
  /// Tinode server host (e.g. "44.234.36.7")
  final String tinodeHost;

  /// Tinode server websocket port (default: 6060)
  final int tinodePort;

  /// Use secure websocket (wss://) instead of ws://
  final bool secure;

  /// Tinode API key for the websocket connection
  final String apiKey;

  /// The application-level user ID (mapped to Tinode user via TAILS)
  final String appUserId;

  /// Application ID for TAILS auth
  final String appId;

  /// Application API key for TAILS auth
  final String appKey;

  /// Unique session identifier
  final String sessionId;

  /// Generates unique request IDs
  final String Function() generateRequestId;

  /// Number of recent messages to fetch when joining a topic (default: 50)
  final int recentMessages;

  /// Number of aggressive reconnect attempts before switching to cover phase
  final int aggressiveAttempts;

  /// Initial delay before first reconnect attempt
  final Duration initialReconnectDelay;

  /// Maximum delay during aggressive reconnect phase
  final Duration maxAggressiveDelay;

  /// Fixed interval during cover reconnect phase
  final Duration coverInterval;

  /// Maximum wall-clock time to keep reconnecting before giving up
  final Duration maxReconnectDuration;

  /// Random jitter factor applied to reconnect delays (0.0 - 1.0)
  final double jitterFactor;

  /// TAGS base URL for identity resolution (e.g. "https://dev-tags.playbonkers.com")
  /// When set, enables TagsIdentityResolver for resolving app user IDs via TAILS.
  /// When null, uses CachedIdentityResolver (local cache only).
  final String? tagsBaseUrl;

  TicTacConfig({
    required this.tinodeHost,
    this.tinodePort = 6060,
    this.secure = false,
    this.apiKey = 'AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K',
    required this.appUserId,
    required this.appId,
    required this.appKey,
    required this.sessionId,
    required this.generateRequestId,
    this.recentMessages = 50,
    this.aggressiveAttempts = 5,
    this.initialReconnectDelay = const Duration(seconds: 1),
    this.maxAggressiveDelay = const Duration(seconds: 16),
    this.coverInterval = const Duration(seconds: 30),
    this.maxReconnectDuration = const Duration(minutes: 7),
    this.jitterFactor = 0.3,
    this.tagsBaseUrl,
  });

  /// Constructs the websocket host:port string for the Tinode SDK
  String get wsHostPort => '$tinodeHost:$tinodePort';
}
