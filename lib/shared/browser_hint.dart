import 'package:flutter/foundation.dart' show kIsWeb;

/// Added to "can't reach the server" in a browser. A browser hides why a
/// request failed, and a server that doesn't allow this page (CORS) looks
/// just like one that is down. The phone and desktop apps never need it.
String corsHint({bool web = kIsWeb, String? page}) {
  if (!web) return '';
  final origin = page ?? Uri.base.origin;
  return ' If it is running, it may not allow this page: on the server, set '
      'SOLITON_CORS_ORIGINS=$origin and restart it.';
}
