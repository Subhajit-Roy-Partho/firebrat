/// Pure decision logic for "may this download run on the current network?".
///
/// No Flutter, plugin or I/O dependency: inputs are the user's preference,
/// what kind of network is up, an optional metered flag and the file size.
/// Everything that actually reads connectivity or shows UI lives in
/// `network_gate.dart` and the host app; this file is the single place the
/// rule is decided, so it can be unit-tested exhaustively.
library;

/// The user's "Download over" setting.
enum DownloadNetworkPreference {
  /// Large downloads only on Wi-Fi / Ethernet; otherwise wait.
  wifiOnly('wifiOnly', 'Wi-Fi only'),

  /// No restriction (the behaviour before this setting existed, so it is the
  /// default for every existing user).
  wifiAndCellular('wifiAndCellular', 'Wi-Fi and cellular'),

  /// Ask before any download larger than [NetworkPolicy.askThresholdBytes]
  /// while on cellular / metered; smaller files just go ahead.
  askOnCellular('askOnCellular', 'Ask on cellular');

  final String storageValue;
  final String label;
  const DownloadNetworkPreference(this.storageValue, this.label);

  /// Parses a persisted value. Unknown / missing values (older app versions
  /// never wrote one) map to [wifiAndCellular] so behaviour is unchanged.
  static DownloadNetworkPreference parse(String? raw) {
    for (final v in values) {
      if (v.storageValue == raw) return v;
    }
    return wifiAndCellular;
  }
}

/// Coarse kind of the active connection.
enum NetworkKind {
  wifi('Wi-Fi'),
  ethernet('Ethernet'),
  cellular('Cellular'),

  /// VPN / Bluetooth / unknown: we cannot tell if it is metered, so it is
  /// treated like cellular whenever the user restricted cellular use.
  other('Other network'),
  none('Offline');

  final String label;
  const NetworkKind(this.label);
}

/// What the app currently knows about the network.
class NetworkSnapshot {
  final NetworkKind kind;

  /// Android's "metered" flag when the host can read it; null if unknown.
  /// A metered Wi-Fi (mobile hotspot) is then treated like cellular.
  final bool? isMetered;
  const NetworkSnapshot(this.kind, {this.isMetered});

  static const offline = NetworkSnapshot(NetworkKind.none);

  bool get isOnline => kind != NetworkKind.none;

  /// True for a connection we are sure is unmetered.
  bool get isUnmetered =>
      (kind == NetworkKind.wifi || kind == NetworkKind.ethernet) &&
      isMetered != true;

  String get label => kind == NetworkKind.none
      ? kind.label
      : (isMetered == true && kind != NetworkKind.cellular
            ? '${kind.label} (metered)'
            : kind.label);

  @override
  bool operator ==(Object other) =>
      other is NetworkSnapshot &&
      other.kind == kind &&
      other.isMetered == isMetered;
  @override
  int get hashCode => Object.hash(kind, isMetered);
}

enum NetworkDecision {
  /// Start / continue the transfer.
  allow,

  /// Do not transfer now; show "Waiting for Wi-Fi" and resume automatically.
  wait,

  /// Ask the user (showing the size) before transferring on this network.
  ask,
}

class NetworkPolicy {
  /// Files at or below this size never trigger the "ask" prompt.
  final int askThresholdBytes;
  const NetworkPolicy({this.askThresholdBytes = defaultAskThresholdBytes});

  static const int defaultAskThresholdBytes = 50 * 1024 * 1024;

  /// Models above this size get an extra "use Wi-Fi" recommendation.
  static const int bigDownloadBytes = 300 * 1024 * 1024;

  NetworkDecision decide({
    required DownloadNetworkPreference preference,
    required NetworkSnapshot network,
    required int sizeBytes,
  }) {
    if (network.kind == NetworkKind.none) {
      // Unrestricted users keep the old behaviour (the transfer simply fails
      // and is retried by the user); restricted users are not failed, they wait.
      return preference == DownloadNetworkPreference.wifiAndCellular
          ? NetworkDecision.allow
          : NetworkDecision.wait;
    }
    if (preference == DownloadNetworkPreference.wifiAndCellular ||
        network.isUnmetered) {
      return NetworkDecision.allow;
    }
    switch (preference) {
      case DownloadNetworkPreference.wifiOnly:
        return NetworkDecision.wait;
      case DownloadNetworkPreference.askOnCellular:
        return sizeBytes > askThresholdBytes
            ? NetworkDecision.ask
            : NetworkDecision.allow;
      case DownloadNetworkPreference.wifiAndCellular:
        return NetworkDecision.allow;
    }
  }

  /// True when the UI should nudge the user towards Wi-Fi for this size.
  bool recommendsWifi(int sizeBytes) => sizeBytes >= bigDownloadBytes;

  /// Human text for a waiting download.
  static String waitingLabel(
    DownloadNetworkPreference preference,
    NetworkSnapshot network,
  ) {
    if (!network.isOnline) return 'Waiting for network';
    return 'Waiting for Wi-Fi';
  }

  static String formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    }
    return '${(bytes / 1048576).toStringAsFixed(bytes >= 10 * 1048576 ? 0 : 1)} MB';
  }
}
