import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';

DeviceCapabilities phone(
  double gb, {
  int sdk = 34,
  Set<String> providers = const {'CPU', 'NNAPI', 'XNNPACK'},
}) => DeviceCapabilities(
  totalRamMb: (gb * 1024).round(),
  androidSdk: sdk,
  ortProviders: providers,
  supportedAbis: const ['arm64-v8a'],
);

void main() {
  group('LLM catalog', () {
    test('unique ids and files, valid fields', () {
      final ids = <String>{};
      final files = <String>{};
      for (final m in kOnDeviceLlmCatalog) {
        expect(ids.add(m.id), isTrue, reason: 'duplicate id ${m.id}');
        expect(
          files.add(m.fileName),
          isTrue,
          reason: 'duplicate file ${m.fileName}',
        );
        expect(m.displayName, isNotEmpty);
        expect(m.fileName, endsWith('.gguf'));
        expect(m.approxSizeBytes, greaterThan(100 * 1024 * 1024));
        expect(
          m.minDeviceRamGb,
          greaterThanOrEqualTo(m.approxRamGb),
          reason: m.id,
        );
        expect(
          m.minDeviceRamGb * 1024 * 1024 * 1024,
          greaterThan(m.approxSizeBytes),
          reason: m.id,
        );
        expect(m.license, isNotEmpty);
        expect(Uri.parse(m.downloadUrl).host, 'huggingface.co');
        expect(
          m.downloadUrl,
          startsWith('https://huggingface.co/${m.hfRepo}/resolve/main/'),
        );
        expect(m.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: m.id);
        expect(m.acceleration, contains(AccelBackend.cpu));
      }
    });
    test('existing ids, the default and their files are unchanged', () {
      for (final id in [
        'qwen3-0.6b',
        'smollm2-1.7b',
        'qwen3-1.7b',
        'llama-3.2-3b',
        'qwen3-4b',
        'gemma-3-1b',
        'gemma-3-4b',
        'phi-4-mini',
      ]) {
        expect(findOnDeviceLlmModel(id).id, id);
      }
      expect(kDefaultOnDeviceLlmId, 'qwen3-1.7b');
      expect(findOnDeviceLlmModel('qwen3-4b').approxSizeBytes, 2497280736);
      expect(findOnDeviceLlmModel('nonsense').id, kDefaultOnDeviceLlmId);
      expect(findOnDeviceLlmModel(null).tier, ModelTier.light);
    });
    test('every tier is populated and larger tiers need more RAM / bytes', () {
      for (final t in ModelTier.values) {
        expect(
          kOnDeviceLlmCatalog.where((m) => m.tier == t),
          isNotEmpty,
          reason: t.label,
        );
      }
      double maxRam(ModelTier t) => kOnDeviceLlmCatalog
          .where((m) => m.tier == t)
          .map((m) => m.minDeviceRamGb)
          .reduce((a, b) => a > b ? a : b);
      double minRam(ModelTier t) => kOnDeviceLlmCatalog
          .where((m) => m.tier == t)
          .map((m) => m.minDeviceRamGb)
          .reduce((a, b) => a < b ? a : b);
      int maxSize(ModelTier t) => kOnDeviceLlmCatalog
          .where((m) => m.tier == t)
          .map((m) => m.approxSizeBytes)
          .reduce((a, b) => a > b ? a : b);
      for (var i = 0; i + 1 < ModelTier.values.length; i++) {
        final lo = ModelTier.values[i], hi = ModelTier.values[i + 1];
        expect(maxRam(hi), greaterThan(maxRam(lo)));
        expect(minRam(hi), greaterThanOrEqualTo(minRam(lo)));
        expect(maxSize(hi), greaterThan(maxSize(lo)));
      }
      final sorted = llmModelsByTier();
      for (var i = 1; i < sorted.length; i++) {
        expect(
          sorted[i].tier.index,
          greaterThanOrEqualTo(sorted[i - 1].tier.index),
        );
      }
    });
    test('the safe default is Light, small and offered on a 4 GB phone', () {
      final d = findOnDeviceLlmModel(null);
      expect(d.tier, ModelTier.light);
      expect(
        assessFit(
          name: d.displayName,
          minDeviceRamGb: d.minDeviceRamGb,
          device: phone(3.7),
        ).fit,
        ModelFit.good,
      );
    });
  });

  group('TTS catalog', () {
    test(
      'unique ids, pinned URLs, checksums; default is the verified int8 model',
      () {
        final ids = <String>{};
        for (final m in kOnDeviceTtsCatalog) {
          expect(ids.add(m.id), isTrue);
          expect(m.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
          expect(m.downloadUrl, contains(kKokoroRevision));
          expect(m.downloadUrl, endsWith(m.repoPath));
          expect(m.license, 'Apache-2.0');
          expect(m.acceleration, contains(AccelBackend.cpu));
        }
        expect(kOnDeviceTtsCatalog.first.id, kDefaultTtsModelId);
        expect(findTtsModel(null).id, kDefaultTtsModelId);
        expect(findTtsModel('zzz').verifiedOnDevice, isTrue);
        expect(kOnDeviceTtsCatalog.where((m) => m.verifiedOnDevice).length, 1);
        expect(
          findTtsModel(kDefaultTtsModelId).sha256,
          '0d55b15d4b735d61a21b0105136bc81b8768c4db94753193c19354fa863cd556',
        );
      },
    );
    test('tier ordering: bigger file / more RAM for higher tier', () {
      for (var i = 1; i < kOnDeviceTtsCatalog.length; i++) {
        final a = kOnDeviceTtsCatalog[i - 1], b = kOnDeviceTtsCatalog[i];
        expect(b.tier.index, greaterThan(a.tier.index));
        expect(b.approxSizeBytes, greaterThan(a.approxSizeBytes));
        expect(b.minDeviceRamGb, greaterThanOrEqualTo(a.minDeviceRamGb));
      }
    });
    test(
      'voices: unique names/files, bundled six unchanged, extras flagged',
      () {
        final names = kKokoroVoiceCatalog.map((v) => v.name).toList();
        expect(names.toSet().length, names.length);
        expect(names.take(6), [
          'Default',
          'Bella',
          'Nicole',
          'Sarah',
          'Adam',
          'Michael',
        ]);
        expect(kKokoroVoiceCatalog.where((v) => v.bundled).length, 6);
        expect(kKokoroExtraVoices.map((v) => v.name), [
          'Sky',
          'Emma',
          'Isabella',
          'George',
          'Lewis',
        ]);
        for (final v in kKokoroVoiceCatalog) {
          expect(v.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
          expect(v.downloadUrl, contains(kKokoroRevision));
        }
        expect(kKokoroVoices, names);
      },
    );
    test(
      'voice casting pools: legacy auto-casting unchanged, new voices selectable as presets',
      () {
        expect(kKokoroMaleVoices, ['Adam', 'Michael']);
        expect(kKokoroFemaleVoices, ['Default', 'Bella', 'Nicole', 'Sarah']);
        expect(
          kKokoroAllMaleVoices,
          containsAll(['Adam', 'Michael', 'George', 'Lewis']),
        );
        expect(
          kKokoroAllFemaleVoices,
          containsAll(['Sky', 'Emma', 'Isabella', 'Sarah']),
        );
      },
    );
  });

  group('device capabilities and recommendation', () {
    test('RAM -> tier boundaries (marketed vs reported RAM)', () {
      expect(phone(3).tier, ModelTier.light);
      expect(phone(5.5).tier, ModelTier.balanced);
      expect(phone(7.4).tier, ModelTier.powerful);
      expect(phone(9).tier, ModelTier.powerful);
      expect(phone(11.2).tier, ModelTier.desktopClass);
      expect(phone(15).tier, ModelTier.desktopClass);
      expect(DeviceCapabilities.unknown.tier, ModelTier.light);
    });
    test(
      'recommendLlm never exceeds the phone and never recommends non-fitting models',
      () {
        expect(
          recommendLlm(DeviceCapabilities.unknown).id,
          kDefaultOnDeviceLlmId,
        );
        expect(recommendLlm(phone(3)).tier, ModelTier.light);
        expect(
          recommendLlm(phone(6)).tier.index,
          lessThanOrEqualTo(ModelTier.balanced.index),
        );
        expect(
          recommendLlm(phone(8)).tier.index,
          greaterThanOrEqualTo(ModelTier.balanced.index),
        );
        expect(recommendLlm(phone(12)).tier, ModelTier.powerful);
        expect(recommendLlm(phone(16)).tier, ModelTier.desktopClass);
        for (final gb in [2.0, 3.0, 4.0, 6.0, 8.0, 12.0, 16.0, 24.0]) {
          final r = recommendLlm(phone(gb));
          expect(
            assessFit(
              name: r.displayName,
              minDeviceRamGb: r.minDeviceRamGb,
              device: phone(gb),
            ).fit,
            r.id == kDefaultOnDeviceLlmId ? isNotNull : ModelFit.good,
            reason: '$gb GB -> ${r.id}',
          );
        }
      },
    );
    test('assessFit warns in plain words', () {
      final tooBig = assessFit(
        name: 'Qwen3 14B',
        minDeviceRamGb: 16,
        device: phone(4),
      );
      expect(tooBig.fit, ModelFit.tooLarge);
      expect(tooBig.warning, allOf(contains('16 GB'), contains('4 GB')));
      final tight = assessFit(name: 'X', minDeviceRamGb: 6, device: phone(5));
      expect(tight.fit, ModelFit.tight);
      expect(
        assessFit(name: 'X', minDeviceRamGb: 6, device: phone(8)).warning,
        isNull,
      );
      expect(
        assessFit(
          name: 'X',
          minDeviceRamGb: 10,
          device: DeviceCapabilities.unknown,
        ).fit,
        ModelFit.tight,
      );
    });
    test('NNAPI usability needs the provider and Android 10+', () {
      expect(phone(8).nnapiUsable, isTrue);
      expect(phone(8, sdk: 28).nnapiUsable, isFalse);
      expect(phone(8, providers: const {'CPU'}).nnapiUsable, isFalse);
      expect(phone(8).ttsBackends, [
        AccelBackend.cpu,
        AccelBackend.xnnpack,
        AccelBackend.nnapi,
      ]);
    });
  });

  group('settings migration', () {
    test(
      'legacy accelerator values map as before; missing means Auto (= CPU for the default model)',
      () {
        expect(AcceleratorPreference.parse('cpu'), AcceleratorPreference.cpu);
        expect(
          AcceleratorPreference.parse('nnapi'),
          AcceleratorPreference.gpuNpu,
        );
        expect(AcceleratorPreference.parse(null), AcceleratorPreference.auto);
        expect(AcceleratorPreference.parse('???'), AcceleratorPreference.auto);
        for (final p in AcceleratorPreference.values) {
          expect(AcceleratorPreference.parse(p.storageValue), p);
        }
        final plan = planAccelerators(
          preference: AcceleratorPreference.parse(null),
          device: phone(16),
          model: findTtsModel(kDefaultTtsModelId),
        );
        expect(plan, [AccelBackend.cpu]);
      },
    );
    test(
      'an old ConversionRequest JSON (no new keys) still loads with safe defaults',
      () {
        final json = ConversionRequest(
          pdfPath: '/a.pdf',
          booksRootDir: '/b',
          modelsDir: '/m',
          llmBaseUrl: '',
          llmApiKey: '',
          llmModel: '',
        ).toJson();
        json.remove('ttsModelId');
        json.remove('deviceRamMb');
        json.remove('androidSdk');
        final r = ConversionRequest.fromJson(json);
        expect(r.ttsModelId, 'kokoro-int8');
        expect(r.deviceRamMb, isNull);
        expect(r.kokoroAcceleration, 'cpu');
        final round = ConversionRequest.fromJson(
          ConversionRequest(
            pdfPath: '/a.pdf',
            booksRootDir: '/b',
            modelsDir: '/m',
            llmBaseUrl: '',
            llmApiKey: '',
            llmModel: '',
            ttsModelId: 'kokoro-fp16',
            deviceRamMb: 8000,
            androidSdk: 34,
            kokoroAcceleration: 'auto',
          ).toJson(),
        );
        expect(
          (
            round.ttsModelId,
            round.deviceRamMb,
            round.androidSdk,
            round.kokoroAcceleration,
          ),
          ('kokoro-fp16', 8000, 34, 'auto'),
        );
      },
    );
  });
}
