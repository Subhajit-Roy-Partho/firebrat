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

/// Play Integrity token path (production-ready minting; no enforcement
/// beyond caller policy, no server verification yet).
///
/// Scope is deliberately narrow:
/// - Token minting over the `firebrat/integrity` MethodChannel only.
/// - **No server verification wired yet** — [verifyRemotely] is an explicit
///   `UnimplementedError` placeholder so nobody mistakes this for enforced
///   attestation.
/// - **No launch gating, no playback-path calls.** Playback stays fully
///   offline-first; attestation (when enforced later) applies to remote/
///   sensitive calls only.
///
/// Policy helpers encode the intended direction:
/// - [checkLocal]: fail-OPEN — any mint failure still allows local use.
/// - [checkRemote]: fail-CLOSED — a missing token denies the remote call
///   (until server verification lands, denial is the caller's decision and
///   this just reports the missing token).
/// - [isRetryable]: transient vs permanent mint failures per the Play
///   Integrity response-code taxonomy (lib-1). Retryable failures mean
///   "try again later / queue offline"; anything else is fail-closed now.
class IntegrityService {
  IntegrityService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('firebrat/integrity');

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

  /// Debug/dev unsigned fallback. True outside release builds so a debug
  /// build with no `--dart-define=FIREBRAT_CLOUD_PROJECT_NUMBER` proceeds
  /// unsigned (MISSING_PLUGIN-style) instead of surfacing `NOT_PREPARED`
  /// as offline-queued. Release stays fail-closed. Tests override this
  /// via [devBypassOverride] to simulate both modes (`kReleaseMode` is
  /// compile-time and always false under `flutter test`).
  @visibleForTesting
  static bool? devBypassOverride;

  static bool get devBypassEnabled => devBypassOverride ?? !kReleaseMode;

  /// UI copy for the offline-retryable path. Keep the words "Offline" and
  /// "queued" in this string — screens match on them for the queued state.
  static const String offlineQueuedMessage =
      'Offline — queued and will retry when online.';

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
  };

  /// True when [errorCode] names a transient failure the caller should
  /// retry later (or surface as [offlineQueuedMessage]) instead of
  /// treating as a hard attestation denial.
  static bool isRetryable(String? errorCode) =>
      errorCode != null && retryableCodes.contains(errorCode);

  /// True when [result] is a transient failure worth queueing offline.
  bool shouldQueueOffline(IntegrityResult result) =>
      !result.ok && isRetryable(result.errorCode);

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

  /// Production token path for a remote call: warm the provider when a
  /// cloud project number is configured, mint one standard token bound to
  /// [requestHash], and recover once from `NOT_PREPARED` by re-preparing
  /// before giving up. When no project number is configured (debug builds
  /// without `--dart-define=FIREBRAT_CLOUD_PROJECT_NUMBER`), a
  /// `NOT_PREPARED` mint becomes a debug dev-bypass (`MISSING_PLUGIN`,
  /// non-retryable, fail-open local + proceed unsigned) with a telemetry
  /// log — never offline-queued. Release with no project number stays
  /// fail-closed (the raw `NOT_PREPARED` is returned, retryable → queued).
  /// Never throws — failures come back as an [IntegrityResult] with an
  /// [IntegrityResult.errorCode] the caller maps via
  /// [isRetryable]/[checkRemote].
  Future<IntegrityResult> mintForRemote({
    required String requestHash,
    int? cloudProjectNumber,
  }) async {
    final project = cloudProjectNumber ?? cloudProjectNumberOrNull;
    if (project == null) {
      // No warm-up possible without a project number: attempt the mint so
      // an already-warm provider (or off-Android MISSING_PLUGIN) still
      // surfaces, then dev-bypass a NOT_PREPARED miss in debug only.
      final result = await requestStandard(requestHash: requestHash);
      if (result.ok) return result;
      if (result.errorCode == 'NOT_PREPARED' && devBypassEnabled) {
        debugPrint(
          'Integrity dev-bypass: cloudProjectNumber unconfigured; '
          'proceeding unsigned (debug only, was NOT_PREPARED).',
        );
        return const IntegrityResult(
            token: null, errorCode: 'MISSING_PLUGIN');
      }
      return result;
    }
    await prepareStandard(cloudProjectNumber: project);
    var result = await requestStandard(requestHash: requestHash);
    if (!result.ok && result.errorCode == 'NOT_PREPARED') {
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
          ? offlineQueuedMessage
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
