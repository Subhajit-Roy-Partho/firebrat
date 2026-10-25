import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/battery_provider.dart';

const _kBatteryExplanation =
    'A whole book can take an hour or more. Firebrat keeps converting in the background '
    '(the notification stays up, and it continues if you leave the app or turn the screen off), '
    'but Android may still pause apps under battery optimization. For the best result, allow '
    'Firebrat unrestricted battery use and keep the phone plugged in.';

/// Banner shown while battery optimization could interrupt a conversion.
/// Disappears once the user allows unrestricted use, re-checking each time the
/// app returns from the system settings page.
class BatteryNotice extends ConsumerStatefulWidget {
  const BatteryNotice({super.key});

  @override
  ConsumerState<BatteryNotice> createState() => _BatteryNoticeState();
}

class _BatteryNoticeState extends ConsumerState<BatteryNotice> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(batteryUnrestrictedProvider);
  }

  @override
  Widget build(BuildContext context) {
    final unrestricted = ref.watch(batteryUnrestrictedProvider).value ?? true;
    if (unrestricted) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('battery-notice'),
      width: double.infinity,
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.battery_alert_rounded, color: scheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Battery optimization is on for Firebrat. $_kBatteryExplanation',
                  style: TextStyle(color: scheme.onTertiaryContainer),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: openBatterySettings,
              icon: const Icon(Icons.settings_rounded),
              label: const Text('Open battery settings'),
            ),
          ),
        ],
      ),
    );
  }
}

bool _explainedThisLaunch = false;

/// Before a conversion starts: if battery optimization is on, explain why that
/// matters and offer to open the settings. Shown once per app launch; the
/// banner on the Conversions screen keeps reminding after that.
Future<void> explainBatteryIfNeeded(BuildContext context, WidgetRef ref) async {
  if (_explainedThisLaunch) return;
  final unrestricted = await ref.read(batteryUnrestrictedProvider.future);
  if (unrestricted || !context.mounted) return;
  _explainedThisLaunch = true;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.battery_charging_full_rounded),
      title: const Text('Keep the conversion running'),
      content: Text(_kBatteryExplanation),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Continue anyway')),
        FilledButton(
          onPressed: () {
            openBatterySettings();
            Navigator.of(ctx).pop();
          },
          child: const Text('Open battery settings'),
        ),
      ],
    ),
  );
}
