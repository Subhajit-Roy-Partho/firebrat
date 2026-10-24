import 'package:flutter_test/flutter_test.dart';
import 'package:firebrat_app/utils/server_url.dart';

void main() {
  test('explicit HTTPS endpoint retains its standard port and path', () {
    const url = 'https://firebrat-review-server.rohu-hexatonic.ts.net';
    expect(normalizeServerUrl(url), url);
    expect(normalizeServerUrl(' https://example.com/firebrat/ '),
        'https://example.com/firebrat/');
  });
  test('bare local addresses receive the backend port', () {
    expect(normalizeServerUrl('100.87.251.5'), 'http://100.87.251.5:8000');
    expect(normalizeServerUrl('localhost'), 'http://localhost:8000');
    expect(normalizeServerUrl('[::1]'), 'http://[::1]:8000');
  });
  test('explicit ports and HTTP reverse proxies are preserved', () {
    expect(normalizeServerUrl('https://example.com:8443/api'),
        'https://example.com:8443/api');
    expect(normalizeServerUrl('http://localhost:8000'), 'http://localhost:8000');
    expect(normalizeServerUrl('http://example.com'), 'http://example.com');
    expect(normalizeServerUrl('localhost:9000'), 'http://localhost:9000');
    expect(normalizeServerUrl(''), '');
  });
}
