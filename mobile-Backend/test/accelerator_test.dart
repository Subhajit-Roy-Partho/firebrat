import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';

class _Sess {
  final AccelBackend backend;
  bool closed = false;
  _Sess(this.backend);
}

DeviceCapabilities _dev({
  int gb = 8,
  int sdk = 34,
  Set<String> p = const {'CPU', 'NNAPI', 'XNNPACK'},
}) =>
    DeviceCapabilities(totalRamMb: gb * 1024, androidSdk: sdk, ortProviders: p);

void main() {
  final int8 = findTtsModel('kokoro-int8');
  final fp16 = findTtsModel('kokoro-fp16');

  group('planAccelerators', () {
    test('CPU preference is CPU only', () {
      expect(
        planAccelerators(
          preference: AcceleratorPreference.cpu,
          device: _dev(),
          model: fp16,
        ),
        [AccelBackend.cpu],
      );
    });
    test('Auto stays on CPU for the default int8 model even on a flagship', () {
      expect(
        planAccelerators(
          preference: AcceleratorPreference.auto,
          device: _dev(gb: 16),
          model: int8,
        ),
        [AccelBackend.cpu],
      );
    });
    test(
      'Auto tries NNAPI for fp16 on a capable phone, never on weak/old ones',
      () {
        expect(
          planAccelerators(
            preference: AcceleratorPreference.auto,
            device: _dev(),
            model: fp16,
          ),
          [AccelBackend.nnapi, AccelBackend.cpu],
        );
        expect(
          planAccelerators(
            preference: AcceleratorPreference.auto,
            device: _dev(gb: 3),
            model: fp16,
          ),
          [AccelBackend.cpu],
        );
        expect(
          planAccelerators(
            preference: AcceleratorPreference.auto,
            device: _dev(sdk: 28),
            model: fp16,
          ),
          [AccelBackend.cpu],
        );
        expect(
          planAccelerators(
            preference: AcceleratorPreference.auto,
            device: _dev(p: {'CPU'}),
            model: fp16,
          ),
          [AccelBackend.cpu],
        );
      },
    );
    test(
      'GPU/NPU: NNAPI then CPU; XNNPACK when no NNAPI; tries NNAPI if probe unknown',
      () {
        expect(
          planAccelerators(
            preference: AcceleratorPreference.gpuNpu,
            device: _dev(),
            model: int8,
          ),
          [AccelBackend.nnapi, AccelBackend.cpu],
        );
        expect(
          planAccelerators(
            preference: AcceleratorPreference.gpuNpu,
            device: _dev(p: {'CPU', 'XNNPACK'}),
            model: int8,
          ),
          [AccelBackend.xnnpack, AccelBackend.cpu],
        );
        expect(
          planAccelerators(
            preference: AcceleratorPreference.gpuNpu,
            device: _dev(p: {'CPU'}),
            model: int8,
          ),
          [AccelBackend.cpu],
        );
        expect(
          planAccelerators(
            preference: AcceleratorPreference.gpuNpu,
            device: DeviceCapabilities.unknown,
            model: int8,
          ),
          [AccelBackend.nnapi, AccelBackend.cpu],
        );
      },
    );
    test('every plan ends with CPU', () {
      for (final pref in AcceleratorPreference.values) {
        for (final d in [
          _dev(),
          _dev(gb: 2),
          DeviceCapabilities.unknown,
          _dev(p: {'CPU'}),
        ]) {
          for (final m in kOnDeviceTtsCatalog) {
            expect(
              planAccelerators(preference: pref, device: d, model: m).last,
              AccelBackend.cpu,
            );
          }
        }
      }
    });
  });

  group('AcceleratedSession (fake runtime)', () {
    test('opens the first back end that works and reports it', () async {
      final created = <AccelBackend>[];
      final s = AcceleratedSession<_Sess>(
        plan: const [AccelBackend.nnapi, AccelBackend.cpu],
        create: (b) async {
          created.add(b);
          return _Sess(b);
        },
        close: (x) async => x.closed = true,
      );
      await s.open();
      expect(s.active, AccelBackend.nnapi);
      expect(s.fellBack, isFalse);
      expect(s.statusLabel, startsWith('NNAPI'));
      expect(created, [AccelBackend.nnapi]);
    });

    test(
      'falls back to CPU when the accelerated session cannot be created',
      () async {
        final s = AcceleratedSession<_Sess>(
          plan: const [AccelBackend.nnapi, AccelBackend.cpu],
          create: (b) async {
            if (b == AccelBackend.nnapi) {
              throw StateError('NNAPI rejected the model');
            }
            return _Sess(b);
          },
          close: (x) async {},
        );
        await s.open();
        expect(s.active, AccelBackend.cpu);
        expect(s.fellBack, isTrue);
        expect(s.statusLabel, startsWith('CPU'));
        expect(s.statusLabel, contains('fell back'));
        expect(s.notes.single, contains('NNAPI'));
      },
    );

    test(
      'a run failure on the accelerator switches to CPU once and retries',
      () async {
        final made = <_Sess>[];
        final s = AcceleratedSession<_Sess>(
          plan: const [AccelBackend.nnapi, AccelBackend.cpu],
          create: (b) async => (made..add(_Sess(b))).last,
          close: (x) async => x.closed = true,
        );
        await s.open();
        final out = await s.run((sess) async {
          if (sess.backend == AccelBackend.nnapi) {
            throw StateError('driver crash');
          }
          return 'audio-on-${sess.backend.name}';
        });
        expect(out, 'audio-on-cpu');
        expect(s.active, AccelBackend.cpu);
        expect(made.first.closed, isTrue);
        expect(s.notes.last, contains('switching to CPU'));
        // later runs just use CPU
        expect(await s.run((x) async => x.backend.name), 'cpu');
        expect(made.length, 2);
      },
    );

    test('CPU errors are real errors, not retried', () async {
      var calls = 0;
      final s = AcceleratedSession<_Sess>(
        plan: const [AccelBackend.cpu],
        create: (b) async => _Sess(b),
        close: (x) async {},
      );
      await expectLater(
        s.run((x) async {
          calls++;
          throw StateError('bad input');
        }),
        throwsStateError,
      );
      expect(calls, 1);
    });

    test('throws a clear error if nothing can be opened', () async {
      final s = AcceleratedSession<_Sess>(
        plan: const [AccelBackend.nnapi, AccelBackend.cpu],
        create: (b) async => throw StateError('no $b'),
        close: (x) async {},
      );
      await expectLater(s.open(), throwsA(isA<StateError>()));
    });

    test('close closes the live session', () async {
      late _Sess made;
      final s = AcceleratedSession<_Sess>(
        plan: const [AccelBackend.cpu],
        create: (b) async => made = _Sess(b),
        close: (x) async => x.closed = true,
      );
      await s.open();
      await s.close();
      expect(made.closed, isTrue);
      expect(s.isOpen, isFalse);
    });
  });
}
