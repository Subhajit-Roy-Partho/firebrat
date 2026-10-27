import 'dart:async';
import 'package:dio/dio.dart';
import 'download_network_policy.dart';

/// Where the gate reads the network and the user's preference from. The host
/// app implements this with `connectivity_plus` + SharedPreferences; tests use
/// a fake with a controllable stream.
abstract class NetworkSource {
  Future<NetworkSnapshot> current();

  /// Emits whenever connectivity (or the stored preference) changes.
  Stream<NetworkSnapshot> get changes;
  Future<DownloadNetworkPreference> preference();
}

/// Called when the policy says [NetworkDecision.ask]. Return true to download
/// now on this network, false to keep waiting for an unrestricted one.
typedef NetworkAsk =
    Future<bool> Function(int sizeBytes, NetworkSnapshot network);

/// Reports a transfer's waiting state: `null` = not waiting.
typedef WaitingCallback = void Function(String? waitingLabel);

/// Thrown into a [CancelToken] when the gate pauses a transfer because the
/// network stopped being allowed (partial data is kept; it resumes later).
const String kNetworkPauseReason = 'network-policy-pause';

/// Enforces the "Download over" preference for any transfer. Never fails a
/// transfer because of the policy: it waits, and resumes by itself.
class NetworkGate {
  final NetworkSource source;
  final NetworkPolicy policy;

  /// Set by the host UI; null means "ask" degrades to waiting.
  NetworkAsk? ask;

  NetworkGate(this.source, {this.policy = const NetworkPolicy(), this.ask});

  Future<NetworkDecision> _decide(int size, {bool approved = false}) async {
    final d = policy.decide(
      preference: await source.preference(),
      network: await source.current(),
      sizeBytes: size,
    );
    return (approved && d == NetworkDecision.ask) ? NetworkDecision.allow : d;
  }

  /// Completes once a transfer of [sizeBytes] is allowed. While not allowed it
  /// reports the waiting label through [onWaiting] and re-evaluates on every
  /// connectivity/preference change. [cancel] aborts the wait (returns false).
  /// An "ask" answer of yes is remembered for the rest of this call only.
  Future<bool> waitUntilAllowed(
    int sizeBytes, {
    WaitingCallback? onWaiting,
    Future<void>? cancel,
    bool Function()? isCancelled,
  }) async {
    var approved = false;
    var askedFor = const NetworkSnapshot(NetworkKind.none);
    var declinedOn = false;
    var wake = Completer<void>();
    void poke() {
      if (!wake.isCompleted) wake.complete();
    }

    final sub = source.changes.listen((_) => poke());
    var cancelled = false;
    cancel?.then((_) {
      cancelled = true;
      poke();
    });
    try {
      while (true) {
        if (cancelled || (isCancelled?.call() ?? false)) return false;
        final decision = await _decide(sizeBytes, approved: approved);
        if (decision == NetworkDecision.allow) {
          onWaiting?.call(null);
          return true;
        }
        final net = await source.current();
        if (decision == NetworkDecision.ask &&
            ask != null &&
            !(declinedOn && askedFor == net)) {
          askedFor = net;
          if (await ask!(sizeBytes, net)) {
            approved = true;
            continue;
          }
          declinedOn = true; // do not re-ask on the same network
        }
        onWaiting?.call(
          NetworkPolicy.waitingLabel(await source.preference(), net),
        );
        await wake.future;
        wake = Completer<void>();
      }
    } finally {
      await sub.cancel();
    }
  }

  /// Runs a resumable transfer under the policy. [run] must keep partial data
  /// when its [CancelToken] fires (HTTP Range resume). If the network stops
  /// being allowed mid-transfer the token is cancelled with
  /// [kNetworkPauseReason], the state becomes "waiting", and [run] is invoked
  /// again (resuming) once an allowed network is back. A user cancel (any other
  /// reason) or any other error propagates unchanged.
  Future<T> runGated<T>(
    int sizeBytes,
    Future<T> Function(CancelToken token) run, {
    WaitingCallback? onWaiting,
    CancelToken? userCancel,
  }) async {
    while (true) {
      final ok = await waitUntilAllowed(
        sizeBytes,
        onWaiting: onWaiting,
        isCancelled: () => userCancel?.isCancelled ?? false,
      );
      if (!ok) {
        throw DioException(
          requestOptions: RequestOptions(path: ''),
          type: DioExceptionType.cancel,
          message: 'cancelled by user while waiting for network',
        );
      }
      final token = CancelToken();
      userCancel?.whenCancel.then((e) {
        if (!token.isCancelled) token.cancel(e.error ?? 'cancelled by user');
      });
      // Watch for the network turning disallowed during the transfer. A remembered
      // "ask" approval is not carried here: a change of network re-asks.
      final watch = source.changes.listen((_) async {
        if (token.isCancelled) return;
        if (await _decide(sizeBytes, approved: true) == NetworkDecision.wait) {
          token.cancel(kNetworkPauseReason);
        }
      });
      try {
        return await run(token);
      } catch (_) {
        // Any failure caused by OUR pause (Dio cancel, or a custom transfer
        // that noticed the token) means: wait, then resume. Others propagate.
        if (token.isCancelled &&
            token.cancelError?.error == kNetworkPauseReason) {
          continue;
        }
        rethrow;
      } finally {
        await watch.cancel();
      }
    }
  }
}

/// True when [token] was cancelled by the network gate (not by the user).
bool isNetworkPause(Object error) =>
    error is DioException &&
    error.type == DioExceptionType.cancel &&
    error.error == kNetworkPauseReason;
