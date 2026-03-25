class ConnectionOptions {
  final String host;
  final String apiKey;
  final bool? secure;
  final Map<String, String>? headers;

  ConnectionOptions(this.host, this.apiKey, {this.secure, this.headers});
}
