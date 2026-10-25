import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Outcome of a Play Integrity token request.
@immutable
class IntegrityResult {
  const IntegrityResult({required this.token, this.errorCode});

  /// Raw integrity token to send to the backend for verification, or null
  /// when minting failed (offline, no Play, throttled, …).
  final String? token;

  /// Stable error code from the native side (e.g. `NETWORK_ERROR`,
  /// `PLAY_STORE_NOT_FOUND`, `NOT_PREPARED`) or null on success.
  final String? errorCode;

  bool get ok => token != null && token!.isNotEmpty;
}

/// Optional Play Integrity token minting. This release has no server-side
/// verification, so ordinary authenticated features do not require a token.
/// Offline reading never calls this service. Enable requiredForRemote only
/// with a configured project and a backend that actually verifies tokens.
class IntegrityService {
  IntegrityService({
    MethodChannel? channel,
    this.requiredForRemote = const bool.fromEnvironment(
      'FIREBRAT_REQUIRE_INTEGRITY',
    ),
  }) : _channel = channel ?? const MethodChannel('firebrat/integrity');

  @visibleForTesting
  static const String channelName = 'firebrat/integrity';

  /// Header name the backend will verify once server-side attestation
  /// lands. Sent best-effort today; enforcement comes later.
  static const String tokenHeaderName = 'X-Firebrat-Integrity';

  /// Cloud project number for `prepareStandard`, injected at build time
  /// with `--dart-define=FIREBRAT_CLOUD_PROJECT_NUMBER=<number>`.
  /// `0`/absent means "not configured" — callers skip the warm-up and go
  /// straight to `requestStandard` (which then reports `NOT_PREPARED` on a
  /// real device, or `MISSING_PLUGIN` off-Android).
  static const int cloudProjectNumber = int.fromEnvironment(
    'FIREBRAT_CLOUD_PROJECT_NUMBER',
    defaultValue: 0,
  );

  /// Null when no project number was baked in at build time.
  static int? get cloudProjectNumberOrNull =>
      cloudProjectNumber > 0 ? cloudProjectNumber : null;

  /// A retry message, not a promise of a persisted background queue.
  static const String retryMessage =
      'Device check is temporarily unavailable. Try again when online. Nothing was uploaded.';

  /// UI copy for the fail-closed remote path (non-retryable mint failure).
  static const String remoteBlockedMessage =
      'Device check failed — remote action blocked. '
      'Local books still work; retry when Play Store is available.';

  /// Transient Play Integrity failures worth retrying (exponential backoff)
  /// or queueing offline, per the Standard/Classic response-code taxonomy:
  /// the network/server/binding was at fault, not the device verdict.
  static const Set<String> retryableCodes = {
    'NETWORK_ERROR',
    'GOOGLE_SERVER_UNAVAILABLE',
    'CLIENT_TRANSIENT_ERROR',
    'TOO_MANY_REQUESTS',
    'CANNOT_BIND_TO_SERVICE',
    'API_NOT_AVAILABLE',
    // Channel-level transport states that are also transient/offline-like.
    'NOT_PREPARED',
    'EMPTY_TOKEN',
    'INTERNAL_ERROR',
    'INTEGRITY_TOKEN_PROVIDER_INVALID',
  };

  /// True when [errorCode] names a transient failure the caller should
  /// retry later (or surface as [retryMessage]) instead of
  /// treating as a hard attestation denial.
  static bool isRetryable(String? errorCode) =>
      errorCode != null && retryableCodes.contains(errorCode);

  /// True when [result] is a transient failure worth queueing offline.
  bool shouldQueueOffline(IntegrityResult result) =>
      !result.ok && isRetryable(result.errorCode);

  /// Disabled until the chosen backend actually verifies tokens. A minted
  /// token alone is not an authorization decision. Firebase/server auth stays
  /// required independently. Never enable this without backend verification.
  final bool requiredForRemote;
  bool allowsRemote(IntegrityResult result) =>
      !requiredForRemote || checkRemote(result);

  final MethodChannel _channel;

  /// Warm the standard provider. Required before [requestStandard].
  /// Returns the native error code on failure, or null on success.
  /// Never throws: failures are reported, and callers apply fail-open
  /// (local) or fail-closed (remote) policy themselves.
  Future<String?> prepareStandard({required int cloudProjectNumber}) async {
    try {
      await _channel.invokeMethod<void>('prepareStandard', {
        'cloudProjectNumber': cloudProjectNumber,
      });
      return null;
    } on PlatformException catch (e) {
      debugPrint('Integrity prepareStandard failed: ${e.code} ${e.message}');
      return e.code;
    } on MissingPluginException catch (e) {
      debugPrint('Integrity channel missing (non-Android/test): $e');
      return 'MISSING_PLUGIN';
    }
  }

  /// Mint a standard integrity token bound to [requestHash].
  Future<IntegrityResult> requestStandard({required String requestHash}) async {
    try {
      final res = await _channel.invokeMethod<Map<Object?, Object?>>(
        'requestStandard',
        {'requestHash': requestHash},
      );
      final token = res?['token'] as String?;
      if (token == null || token.isEmpty) {
        return const IntegrityResult(token: null, errorCode: 'EMPTY_TOKEN');
      }
      return IntegrityResult(token: token);
    } on PlatformException catch (e) {
      debugPrint('Integrity requestStandard failed: ${e.code} ${e.message}');
      return IntegrityResult(token: null, errorCode: e.code);
    } on MissingPluginException catch (e) {
      debugPrint('Integrity channel missing (non-Android/test): $e');
      return const IntegrityResult(token: null, errorCode: 'MISSING_PLUGIN');
    }
  }

  /// Legacy single-shot token bound to [nonce]. Prefer [requestStandard].
  Future<IntegrityResult> requestClassic({required String nonce}) async {
    try {
      final res = await _channel.invokeMethod<Map<Object?, Object?>>(
        'requestClassic',
        {'nonce': nonce},
      );
      final token = res?['token'] as String?;
      if (token == null || token.isEmpty) {
        return const IntegrityResult(token: null, errorCode: 'EMPTY_TOKEN');
      }
      return IntegrityResult(token: token);
    } on PlatformException catch (e) {
      debugPrint('Integrity requestClassic failed: ${e.code} ${e.message}');
      return IntegrityResult(token: null, errorCode: e.code);
    } on MissingPluginException catch (e) {
      debugPrint('Integrity channel missing (non-Android/test): $e');
      return const IntegrityResult(token: null, errorCode: 'MISSING_PLUGIN');
    }
  }

  /// Mint only when a cloud project is configured. Preserve preparation errors
  /// and retry an invalidated provider once. Missing setup never masquerades
  /// as a network outage, and does not block the default authenticated path.
  Future<IntegrityResult> mintForRemote({
    required String requestHash,
    int? cloudProjectNumber,
  }) async {
    final project = cloudProjectNumber ?? cloudProjectNumberOrNull;
    if (project == null) {
      return const IntegrityResult(token: null, errorCode: 'NOT_CONFIGURED');
    }
    final preparationError = await prepareStandard(cloudProjectNumber: project);
    if (preparationError != null) {
      return IntegrityResult(token: null, errorCode: preparationError);
    }
    var result = await requestStandard(requestHash: requestHash);
    if (!result.ok &&
        {
          'NOT_PREPARED',
          'INTEGRITY_TOKEN_PROVIDER_INVALID',
        }.contains(result.errorCode)) {
      // Provider was evicted between warm-up and mint (process restart,
      // binding drop). One re-prepare + re-mint covers the transient case;
      // anything further is fail-closed, not a spin loop.
      await prepareStandard(cloudProjectNumber: project);
      result = await requestStandard(requestHash: requestHash);
    }
    return result;
  }

  /// Derive an opaque request-binding hash for [input] (file path, book id,
  /// …). SHA-256 hex keeps the binding stable without leaking the input;
  /// the native side forwards it verbatim as the standard `requestHash`.
  static String requestHashForString(String input) =>
      sha256.convert(utf8.encode(input)).toString();

  /// User-facing copy for a mint failure: offline-queue hint for
  /// retryable codes, fail-closed denial otherwise.
  static String userMessageFor(IntegrityResult result) =>
      shouldQueueOfflineStatic(result)
      ? retryMessage
      : '${remoteBlockedMessage.split('.').first}. (${result.errorCode ?? 'NO_TOKEN'})';

  @visibleForTesting
  static bool shouldQueueOfflineStatic(IntegrityResult result) =>
      !result.ok && isRetryable(result.errorCode);

  /// Local-use policy: fail-OPEN. A null/false verdict never blocks offline
  /// playback or library access — integrity only ever gates remote calls.
  bool checkLocal(IntegrityResult result) => true;

  /// Remote-call policy: fail-CLOSED. Returns true only when a non-empty
  /// token is present to attach to the request. Server-side verification
  /// is NOT wired yet (see [verifyRemotely]).
  bool checkRemote(IntegrityResult result) => result.ok;

  /// Placeholder for future server verification of [token].
  /// Deliberately unimplemented in the stub — do not call.
  Future<bool> verifyRemotely(String token) {
    throw UnimplementedError(
      'Server verification is not wired yet (lib-1 mints tokens only).',
    );
  }
}

/// App-wide singleton for the token path. Screens and coordinators read
/// this instead of constructing channels directly so tests can override it.
final integrityServiceProvider = Provider<IntegrityService>(
  (ref) => IntegrityService(),
);
