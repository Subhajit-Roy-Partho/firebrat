/// Normalizes server/LLM endpoint URLs entered by hand in Conversion
/// settings, so `100.87.251.5:8000`, `100.87.251.5`, or `https://host`
/// all become something `Dio` can actually reach.
///
/// Cloud server rule (what bit the user on 2026-09-17: entering the
/// Tailscale IP with no `http://` prefix produced an unreachable client):
/// prepend `http://` when no scheme is present, and append `:8000` when
/// no explicit port is present. An explicitly entered scheme or port is
/// never overridden.
String normalizeServerUrl(String raw, {int defaultPort = 8000}) {
  var url = raw.trim();
  if (url.isEmpty) return url;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) {
    url = 'http://$url';
  }
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  if (!uri.hasPort) {
    return uri.replace(port: defaultPort).toString();
  }
  return uri.toString();
}

/// Same missing-scheme forgiveness for the on-device cloud-LLM endpoint,
/// but defaulting to `https://` (nano-gpt/OpenAI are TLS endpoints) and
/// leaving the port alone — cloud LLM URLs carry no default port.
String normalizeLlmUrl(String raw) {
  var url = raw.trim();
  if (url.isEmpty) return url;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) {
    url = 'https://$url';
  }
  return url;
}
