import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebrat_app/services/app_network_gate.dart';
import 'package:firebrat_app/state/on_device_conversion_providers.dart';
import 'package:firebrat_app/widgets/model_choice_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('connectivity results map to network kinds', () {
    NetworkKind k(List<ConnectivityResult> r) => snapshotFromConnectivity(r).kind;
    expect(k([]), NetworkKind.none);
    expect(k([ConnectivityResult.none]), NetworkKind.none);
    expect(k([ConnectivityResult.wifi]), NetworkKind.wifi);
    expect(k([ConnectivityResult.wifi, ConnectivityResult.mobile]), NetworkKind.wifi);
    expect(k([ConnectivityResult.mobile]), NetworkKind.cellular);
    expect(k([ConnectivityResult.vpn, ConnectivityResult.mobile]), NetworkKind.cellular);
    expect(k([ConnectivityResult.ethernet]), NetworkKind.ethernet);
    expect(k([ConnectivityResult.vpn]), NetworkKind.other);
    expect(k([ConnectivityResult.bluetooth]), NetworkKind.other);
  });

  test('download preference: existing users (no key) keep Wi-Fi and cellular; value persists', () async {
    SharedPreferences.setMockInitialValues({});
    final source = PluginNetworkSource();
    expect(await source.preference(), DownloadNetworkPreference.wifiAndCellular);
    await source.setPreference(DownloadNetworkPreference.wifiOnly);
    expect(await source.preference(), DownloadNetworkPreference.wifiOnly);
    SharedPreferences.setMockInitialValues({kDownloadNetworkPrefKey: 'garbage'});
    expect(await PluginNetworkSource().preference(), DownloadNetworkPreference.wifiAndCellular);
  });

  test('legacy saved Kokoro accelerator values migrate; defaults are unchanged for old installs', () async {
    Future<ConversionModeSettings> load(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues(prefs);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(conversionModeProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return c.read(conversionModeProvider);
    }

    final fresh = await load({});
    expect(fresh.kokoroAcceleration, 'auto'); // resolves to CPU for the default model
    expect(fresh.ttsModelId, kDefaultTtsModelId);
    expect(fresh.onDeviceLlmModelId, 'qwen3-1.7b');
    expect(fresh.kokoroVoice, 'Bella');
    expect((await load({'conversion.kokoroAcceleration': 'cpu'})).kokoroAcceleration, 'cpu');
    expect((await load({'conversion.kokoroAcceleration': 'nnapi'})).kokoroAcceleration, 'gpuNpu');
    final saved = await load({'conversion.ttsModelId': 'kokoro-fp16', 'conversion.onDeviceLlmModelId': 'qwen3-8b'});
    expect(saved.ttsModelId, 'kokoro-fp16');
    expect(saved.onDeviceLlmModelId, 'qwen3-8b');
  });

  testWidgets('Download over setting shows three choices, a Wi-Fi recommendation, and saves the choice', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DownloadNetworkSetting()))),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Wi-Fi only'), findsOneWidget);
    expect(find.text('Wi-Fi and cellular'), findsOneWidget);
    expect(find.text('Ask on cellular'), findsOneWidget);
    expect(find.textContaining('Wi-Fi is recommended'), findsOneWidget);
    expect(find.textContaining('Network:'), findsOneWidget);
    await tester.tap(find.text('Wi-Fi only'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(await PluginNetworkSource().preference(), DownloadNetworkPreference.wifiOnly);
  });
}
