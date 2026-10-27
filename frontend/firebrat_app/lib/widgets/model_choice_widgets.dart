import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import '../services/app_network_gate.dart';

/// "Network: Wi-Fi" chip shown next to downloads.
class NetworkStatusChip extends ConsumerWidget {
  const NetworkStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final net = ref.watch(networkSnapshotProvider).asData?.value;
    final label = net?.label ?? 'checking...';
    final icon = switch (net?.kind) {
      NetworkKind.wifi => Icons.wifi_rounded,
      NetworkKind.ethernet => Icons.settings_ethernet_rounded,
      NetworkKind.cellular => Icons.signal_cellular_alt_rounded,
      NetworkKind.none => Icons.signal_wifi_off_rounded,
      _ => Icons.network_check_rounded,
    };
    return Semantics(
      label: 'Current network: $label',
      child: ExcludeSemantics(
        child: Chip(
          visualDensity: VisualDensity.compact,
          avatar: Icon(icon, size: 16),
          label: Text('Network: $label'),
        ),
      ),
    );
  }
}

/// Plain-language warning card (RAM fit, storage, accelerator caveats).
class NoticeCard extends StatelessWidget {
  final String text;
  final IconData icon;
  final bool severe;
  const NoticeCard({
    super.key,
    required this.text,
    this.icon = Icons.info_outline_rounded,
    this.severe = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = severe ? scheme.errorContainer : scheme.surfaceContainerHighest;
    final fg = severe ? scheme.onErrorContainer : scheme.onSurfaceVariant;
    return Semantics(
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "Download over" setting (Wi-Fi only / Wi-Fi and cellular / Ask on cellular).
class DownloadNetworkSetting extends ConsumerWidget {
  const DownloadNetworkSetting({super.key});

  static const _descriptions = {
    DownloadNetworkPreference.wifiOnly:
        'Large downloads wait for Wi-Fi and continue by themselves when it is back. Progress is kept.',
    DownloadNetworkPreference.wifiAndCellular:
        'No restriction (default). Uses mobile data when there is no Wi-Fi.',
    DownloadNetworkPreference.askOnCellular:
        'On mobile data, asks before any download larger than 50 MB and shows its size.',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pref = ref.watch(downloadNetworkProvider);
    final notifier = ref.read(downloadNetworkProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Align(alignment: Alignment.centerLeft, child: NetworkStatusChip()),
        const SizedBox(height: 4),
        RadioGroup<DownloadNetworkPreference>(
          groupValue: pref,
          onChanged: (v) {
            if (v != null) notifier.set(v);
          },
          child: Column(
            children: [
              for (final p in DownloadNetworkPreference.values)
                RadioListTile<DownloadNetworkPreference>(
                  value: p,
                  title: Text(p.label),
                  subtitle: Text(_descriptions[p]!),
                ),
            ],
          ),
        ),
        const NoticeCard(
          icon: Icons.wifi_rounded,
          text:
              'Wi-Fi is recommended for big models: the larger language models are 5-9 GB and the '
              'full-precision voice is 326 MB. This applies to model, book, Drive and community downloads.',
        ),
      ],
    );
  }
}
