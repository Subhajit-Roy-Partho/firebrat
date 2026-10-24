/// Normalizes server/LLM endpoint URLs entered by hand in Conversion
/// settings, so `100.87.251.5:8000`, `100.87.251.5`, or `https://host`
/// all become something `Dio` can actually reach.
///
/// Cloud server rule (what bit the user on 2026-09-17: entering the
/// Tailscale IP with no `http://` prefix produced an unreachable client):
/// Bare addresses get `http://` and port 8000. URLs with an explicit scheme
/// keep its standard port, so HTTPS reverse proxies and Funnel use port 443.
String normalizeServerUrl(String raw, {int defaultPort = 8000}) {
  var url = raw.trim();
  if (url.isEmpty) return url;
  final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url);
  if (!hasScheme) {
    url = 'http://$url';
  }
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  if (!hasScheme && !uri.hasPort) {
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
