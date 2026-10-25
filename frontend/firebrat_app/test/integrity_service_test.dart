import 'package:firebrat_app/services/integrity_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(IntegrityService.channelName);
  final log = <MethodCall>[];

  IntegrityService serviceForHandler(Future<dynamic> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
    return IntegrityService(channel: channel);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    log.clear();
    IntegrityService.devBypassOverride = null;
  });

  test('requestStandard returns token on success', () async {
    final svc = serviceForHandler((call) async {
      log.add(call);
      expect(call.method, 'requestStandard');
      expect((call.arguments as Map)['requestHash'], 'abc');
      return {'token': 'tok123'};
    });
    final res = await svc.requestStandard(requestHash: 'abc');
    expect(res.ok, isTrue);
    expect(res.token, 'tok123');
    expect(svc.checkRemote(res), isTrue);
    expect(svc.checkLocal(res), isTrue);
  });

  test('requestStandard maps PlatformException to fail-open local / fail-closed remote', () async {
    final svc = serviceForHandler((call) async {
      throw PlatformException(code: 'NETWORK_ERROR', message: 'offline');
    });
    final res = await svc.requestStandard(requestHash: 'abc');
    expect(res.ok, isFalse);
    expect(res.errorCode, 'NETWORK_ERROR');
    // Local use stays allowed even when attestation fails.
    expect(svc.checkLocal(res), isTrue);
    // Remote calls are denied without a token.
    expect(svc.checkRemote(res), isFalse);
  });

  test('requestClassic returns token; prepareStandard surfaces error code', () async {
    final svc = serviceForHandler((call) async {
      if (call.method == 'prepareStandard') {
        expect((call.arguments as Map)['cloudProjectNumber'], 123);
        return null;
      }
      return {'token': 'classic-tok'};
    });
    expect(await svc.prepareStandard(cloudProjectNumber: 123), isNull);
    final res = await svc.requestClassic(nonce: 'n');
    expect(res.ok, isTrue);
    expect(res.token, 'classic-tok');
  });

  test('prepareStandard failure returns code, never throws', () async {
    final svc = serviceForHandler((call) async {
      throw PlatformException(code: 'PLAY_STORE_NOT_FOUND');
    });
    expect(await svc.prepareStandard(cloudProjectNumber: 1), 'PLAY_STORE_NOT_FOUND');
  });

  test('verifyRemotely is explicitly unwired', () {
    final svc = IntegrityService(channel: channel);
    expect(() => svc.verifyRemotely('tok'), throwsUnimplementedError);
  });

  test('retryable mapping: transient codes queue offline, verdicts do not', () async {
    for (final code in [
      'NETWORK_ERROR',
      'GOOGLE_SERVER_UNAVAILABLE',
      'CLIENT_TRANSIENT_ERROR',
      'TOO_MANY_REQUESTS',
      'CANNOT_BIND_TO_SERVICE',
      'API_NOT_AVAILABLE',
    ]) {
      expect(IntegrityService.isRetryable(code), isTrue, reason: code);
      final svc = IntegrityService(channel: channel);
      expect(
        svc.shouldQueueOffline(
            IntegrityResult(token: null, errorCode: code)),
        isTrue,
        reason: code,
      );
    }
    for (final code in [
      'PLAY_STORE_NOT_FOUND',
      'APP_NOT_INSTALLED',
      'CLOUD_PROJECT_NUMBER_IS_INVALID',
      'REQUEST_HASH_TOO_LONG',
      'MISSING_PLUGIN',
    ]) {
      expect(IntegrityService.isRetryable(code), isFalse, reason: code);
    }
    // Offline-queued UI copy keeps both keywords for the queued state.
    expect(IntegrityService.offlineQueuedMessage.toLowerCase(),
        contains('queued'));
    expect(IntegrityService.offlineQueuedMessage.toLowerCase(),
        contains('offline'));
  });

  test('mintForRemote recovers once from NOT_PREPARED', () async {
    var requests = 0;
    final svc = serviceForHandler((call) async {
      if (call.method == 'prepareStandard') return null;
      requests++;
      if (requests == 1) throw PlatformException(code: 'NOT_PREPARED');
      return {'token': 'recovered'};
    });
    final res = await svc.mintForRemote(
      requestHash: 'h',
      cloudProjectNumber: 123,
    );
    expect(res.ok, isTrue);
    expect(res.token, 'recovered');
    expect(requests, 2);
  });

  test('requestHashForString is stable hex', () {
    final a = IntegrityService.requestHashForString('upload:a:1');
    final b = IntegrityService.requestHashForString('upload:a:1');
    expect(a, b);
    expect(a.length, 64);
  });

  test('mintForRemote with blank project bypasses NOT_PREPARED in debug',
      () async {
    IntegrityService.devBypassOverride = false;
    try {
      // Blank project (no dart-define in test) + release mode: raw
      // NOT_PREPARED stays retryable → offline-queued (fail-closed).
      final releaseSvc = serviceForHandler((call) async {
        expect(call.method, 'requestStandard');
        throw PlatformException(code: 'NOT_PREPARED');
      });
      final blocked = await releaseSvc.mintForRemote(requestHash: 'h');
      expect(blocked.ok, isFalse);
      expect(blocked.errorCode, 'NOT_PREPARED');
      expect(IntegrityService.isRetryable(blocked.errorCode), isTrue);
      expect(releaseSvc.shouldQueueOffline(blocked), isTrue);
    } finally {
      IntegrityService.devBypassOverride = null;
    }

    // Same blank project in debug (default under flutter test):
    // NOT_PREPARED becomes MISSING_PLUGIN-style dev-bypass —
    // non-retryable, never offline-queued, local stays fail-open.
    final debugSvc = serviceForHandler((call) async {
      expect(call.method, 'requestStandard');
      throw PlatformException(code: 'NOT_PREPARED');
    });
    final bypass = await debugSvc.mintForRemote(requestHash: 'h');
    expect(bypass.ok, isFalse);
    expect(bypass.errorCode, 'MISSING_PLUGIN');
    expect(IntegrityService.isRetryable(bypass.errorCode), isFalse);
    expect(debugSvc.shouldQueueOffline(bypass), isFalse);
    expect(debugSvc.checkLocal(bypass), isTrue);
  });

  test('mintForRemote with blank project still returns real tokens',
      () async {
    final svc = serviceForHandler((call) async {
      expect(call.method, 'requestStandard');
      return {'token': 'warm-provider-tok'};
    });
    final res = await svc.mintForRemote(requestHash: 'h');
    expect(res.ok, isTrue);
    expect(res.token, 'warm-provider-tok');
  });
}
