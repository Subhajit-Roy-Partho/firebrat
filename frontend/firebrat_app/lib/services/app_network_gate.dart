import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Key for the "Download over" preference. Absent for every existing user,
/// which [DownloadNetworkPreference.parse] reads as "Wi-Fi and cellular" - the
/// behaviour before the setting existed.
const String kDownloadNetworkPrefKey = 'download.networkPreference';

/// Maps connectivity_plus results to a [NetworkSnapshot]. (connectivity_plus
/// reports the transport only; Android's "metered" flag is not available
/// through it, so a metered Wi-Fi hotspot looks like plain Wi-Fi.)
NetworkSnapshot snapshotFromConnectivity(List<ConnectivityResult> results) {
  if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
    return NetworkSnapshot.offline;
  }
  if (results.contains(ConnectivityResult.wifi)) {
    return const NetworkSnapshot(NetworkKind.wifi);
  }
  if (results.contains(ConnectivityResult.ethernet)) {
    return const NetworkSnapshot(NetworkKind.ethernet);
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return const NetworkSnapshot(NetworkKind.cellular);
  }
  return const NetworkSnapshot(NetworkKind.other);
}

/// The real [NetworkSource]: connectivity_plus + SharedPreferences. Fails open
/// (reports Wi-Fi) if the plugin is unavailable, so a plugin problem can never
/// block downloads forever.
class PluginNetworkSource implements NetworkSource {
  final _prefChanged = StreamController<NetworkSnapshot>.broadcast();

  @override
  Future<NetworkSnapshot> current() async {
    try {
      return snapshotFromConnectivity(await Connectivity().checkConnectivity());
    } catch (_) {
      return const NetworkSnapshot(NetworkKind.wifi);
    }
  }

  @override
  Stream<NetworkSnapshot> get changes {
    Stream<NetworkSnapshot> connectivity;
    try {
      connectivity = Connectivity().onConnectivityChanged.map(
        snapshotFromConnectivity,
      );
    } catch (_) {
      connectivity = const Stream.empty();
    }
    return _merge(connectivity, _prefChanged.stream);
  }

  static Stream<T> _merge<T>(Stream<T> a, Stream<T> b) {
    final ctl = StreamController<T>.broadcast();
    StreamSubscription<T>? sa, sb;
    ctl.onListen = () {
      sa = a.listen(ctl.add, onError: (_) {});
      sb = b.listen(ctl.add, onError: (_) {});
    };
    ctl.onCancel = () {
      sa?.cancel();
      sb?.cancel();
    };
    return ctl.stream;
  }

  @override
  Future<DownloadNetworkPreference> preference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return DownloadNetworkPreference.parse(
        prefs.getString(kDownloadNetworkPrefKey),
      );
    } catch (_) {
      return DownloadNetworkPreference.wifiAndCellular;
    }
  }

  /// Wakes waiting downloads after the user changed the setting.
  Future<void> setPreference(DownloadNetworkPreference value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kDownloadNetworkPrefKey, value.storageValue);
    _prefChanged.add(await current());
  }
}

/// App-wide gate used by every large download (models, books, Drive,
/// community). Singleton so all transfers share one decision and the
/// settings screen can change it live.
class AppNetworkGate {
  AppNetworkGate._();
  static final PluginNetworkSource source = PluginNetworkSource();
  static final NetworkGate instance = NetworkGate(source, ask: _askUser);

  /// Navigator of the root MaterialApp, used to show the cellular prompt.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static Future<bool> _askUser(int sizeBytes, NetworkSnapshot net) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false; // no UI: keep waiting for Wi-Fi
    final size = NetworkPolicy.formatSize(sizeBytes);
    final answer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.signal_cellular_alt_rounded),
        title: Text(
          'Download $size on ${net.kind == NetworkKind.cellular ? 'mobile data' : net.label}?',
        ),
        content: Text(
          'This download is $size. Wi-Fi is recommended for large files and avoids '
          'using your data plan. If you wait, it starts by itself when Wi-Fi is available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Wait for Wi-Fi'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download now'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }
}

/// Live network type for display next to downloads.
final networkSnapshotProvider = StreamProvider<NetworkSnapshot>((ref) async* {
  yield await AppNetworkGate.source.current();
  yield* AppNetworkGate.source.changes.asyncMap(
    (_) => AppNetworkGate.source.current(),
  );
});

/// The persisted "Download over" setting.
class DownloadNetworkNotifier extends Notifier<DownloadNetworkPreference> {
  @override
  DownloadNetworkPreference build() {
    _load();
    return DownloadNetworkPreference.wifiAndCellular;
  }

  Future<void> _load() async =>
      state = await AppNetworkGate.source.preference();

  Future<void> set(DownloadNetworkPreference value) async {
    state = value;
    await AppNetworkGate.source.setPreference(value);
  }
}

final downloadNetworkProvider =
    NotifierProvider<DownloadNetworkNotifier, DownloadNetworkPreference>(
      DownloadNetworkNotifier.new,
    );
