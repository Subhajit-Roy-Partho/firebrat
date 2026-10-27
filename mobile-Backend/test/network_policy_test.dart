import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';

const _mb = 1024 * 1024;

class _FakeSource implements NetworkSource {
  NetworkSnapshot net;
  DownloadNetworkPreference pref;
  final _ctl = StreamController<NetworkSnapshot>.broadcast();
  _FakeSource(this.net, this.pref);
  @override
  Future<NetworkSnapshot> current() async => net;
  @override
  Future<DownloadNetworkPreference> preference() async => pref;
  @override
  Stream<NetworkSnapshot> get changes => _ctl.stream;
  void set(NetworkSnapshot n) {
    net = n;
    _ctl.add(n);
  }
}

Future<void> pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  const policy = NetworkPolicy();
  const wifi = NetworkSnapshot(NetworkKind.wifi);
  const cell = NetworkSnapshot(NetworkKind.cellular);

  group('NetworkPolicy.decide', () {
    test('default preference allows everything (existing behaviour)', () {
      for (final n in [
        wifi,
        cell,
        const NetworkSnapshot(NetworkKind.other),
        NetworkSnapshot.offline,
      ]) {
        expect(
          policy.decide(
            preference: DownloadNetworkPreference.wifiAndCellular,
            network: n,
            sizeBytes: 5000 * _mb,
          ),
          NetworkDecision.allow,
        );
      }
    });
    test('wifiOnly waits on cellular/other/offline, allows wifi/ethernet', () {
      const p = DownloadNetworkPreference.wifiOnly;
      expect(
        policy.decide(preference: p, network: wifi, sizeBytes: 1),
        NetworkDecision.allow,
      );
      expect(
        policy.decide(
          preference: p,
          network: const NetworkSnapshot(NetworkKind.ethernet),
          sizeBytes: 1,
        ),
        NetworkDecision.allow,
      );
      expect(
        policy.decide(preference: p, network: cell, sizeBytes: 1),
        NetworkDecision.wait,
      );
      expect(
        policy.decide(
          preference: p,
          network: const NetworkSnapshot(NetworkKind.other),
          sizeBytes: 1,
        ),
        NetworkDecision.wait,
      );
      expect(
        policy.decide(
          preference: p,
          network: NetworkSnapshot.offline,
          sizeBytes: 1,
        ),
        NetworkDecision.wait,
      );
    });
    test('metered wifi counts as cellular', () {
      const hotspot = NetworkSnapshot(NetworkKind.wifi, isMetered: true);
      expect(
        policy.decide(
          preference: DownloadNetworkPreference.wifiOnly,
          network: hotspot,
          sizeBytes: 1,
        ),
        NetworkDecision.wait,
      );
      expect(
        policy.decide(
          preference: DownloadNetworkPreference.askOnCellular,
          network: hotspot,
          sizeBytes: 100 * _mb,
        ),
        NetworkDecision.ask,
      );
      expect(hotspot.label, 'Wi-Fi (metered)');
    });
    test('ask only above the threshold (default 50 MB), on cellular', () {
      const p = DownloadNetworkPreference.askOnCellular;
      expect(
        policy.decide(preference: p, network: cell, sizeBytes: 50 * _mb),
        NetworkDecision.allow,
      );
      expect(
        policy.decide(preference: p, network: cell, sizeBytes: 50 * _mb + 1),
        NetworkDecision.ask,
      );
      expect(
        policy.decide(preference: p, network: wifi, sizeBytes: 9000 * _mb),
        NetworkDecision.allow,
      );
      expect(
        policy.decide(
          preference: p,
          network: NetworkSnapshot.offline,
          sizeBytes: 1,
        ),
        NetworkDecision.wait,
      );
      const custom = NetworkPolicy(askThresholdBytes: 10 * _mb);
      expect(
        custom.decide(preference: p, network: cell, sizeBytes: 11 * _mb),
        NetworkDecision.ask,
      );
    });
    test('preference parsing migrates unknown/missing to wifiAndCellular', () {
      expect(
        DownloadNetworkPreference.parse(null),
        DownloadNetworkPreference.wifiAndCellular,
      );
      expect(
        DownloadNetworkPreference.parse('garbage'),
        DownloadNetworkPreference.wifiAndCellular,
      );
      for (final v in DownloadNetworkPreference.values) {
        expect(DownloadNetworkPreference.parse(v.storageValue), v);
      }
    });
    test('recommendation threshold and size text', () {
      expect(policy.recommendsWifi(500 * _mb), isTrue);
      expect(policy.recommendsWifi(20 * _mb), isFalse);
      expect(NetworkPolicy.formatSize(92 * _mb), '92 MB');
      expect(NetworkPolicy.formatSize(5027784224), '4.7 GB');
      expect(
        NetworkPolicy.waitingLabel(DownloadNetworkPreference.wifiOnly, cell),
        'Waiting for Wi-Fi',
      );
      expect(
        NetworkPolicy.waitingLabel(
          DownloadNetworkPreference.wifiOnly,
          NetworkSnapshot.offline,
        ),
        'Waiting for network',
      );
    });
  });

  group('NetworkGate', () {
    test('allowed network: no waiting, completes immediately', () async {
      final src = _FakeSource(wifi, DownloadNetworkPreference.wifiOnly);
      final labels = <String?>[];
      expect(
        await NetworkGate(
          src,
        ).waitUntilAllowed(500 * _mb, onWaiting: labels.add),
        isTrue,
      );
      expect(labels, [null]);
    });

    test(
      'waits on cellular then resumes automatically when Wi-Fi returns',
      () async {
        final src = _FakeSource(cell, DownloadNetworkPreference.wifiOnly);
        final labels = <String?>[];
        var done = false;
        final f = NetworkGate(src)
            .waitUntilAllowed(500 * _mb, onWaiting: labels.add)
            .then((v) => done = v);
        await pump();
        expect(done, isFalse);
        expect(labels.last, 'Waiting for Wi-Fi');
        src.set(NetworkSnapshot.offline);
        await pump();
        expect(labels.last, 'Waiting for network');
        src.set(wifi);
        await f;
        expect(done, isTrue);
        expect(labels.last, isNull);
      },
    );

    test('preference change unblocks a waiting transfer', () async {
      final src = _FakeSource(cell, DownloadNetworkPreference.wifiOnly);
      var done = false;
      final f = NetworkGate(
        src,
      ).waitUntilAllowed(500 * _mb).then((v) => done = v);
      await pump();
      expect(done, isFalse);
      src.pref = DownloadNetworkPreference.wifiAndCellular;
      src.set(cell); // preference change notification
      await f;
      expect(done, isTrue);
    });

    test('ask: yes proceeds, shows the size; small files do not ask', () async {
      final src = _FakeSource(cell, DownloadNetworkPreference.askOnCellular);
      final asked = <int>[];
      final gate = NetworkGate(
        src,
        ask: (size, net) async {
          asked.add(size);
          return true;
        },
      );
      expect(await gate.waitUntilAllowed(10 * _mb), isTrue);
      expect(asked, isEmpty);
      expect(await gate.waitUntilAllowed(100 * _mb), isTrue);
      expect(asked, [100 * _mb]);
    });

    test(
      'ask: no keeps waiting (not failing) and resumes on Wi-Fi; asks once per network',
      () async {
        final src = _FakeSource(cell, DownloadNetworkPreference.askOnCellular);
        var asks = 0;
        final labels = <String?>[];
        final gate = NetworkGate(
          src,
          ask: (s, n) async {
            asks++;
            return false;
          },
        );
        var done = false;
        final f = gate
            .waitUntilAllowed(100 * _mb, onWaiting: labels.add)
            .then((v) => done = v);
        await pump();
        src.set(cell);
        await pump();
        expect(asks, 1);
        expect(done, isFalse);
        expect(labels.last, 'Waiting for Wi-Fi');
        src.set(wifi);
        await f;
        expect(done, isTrue);
      },
    );

    test('ask without a UI handler degrades to waiting', () async {
      final src = _FakeSource(cell, DownloadNetworkPreference.askOnCellular);
      var done = false;
      final f = NetworkGate(
        src,
      ).waitUntilAllowed(100 * _mb).then((v) => done = v);
      await pump();
      expect(done, isFalse);
      src.set(wifi);
      await f;
    });

    test('runGated: starts only on an allowed network', () async {
      final src = _FakeSource(cell, DownloadNetworkPreference.wifiOnly);
      var starts = 0;
      final f = NetworkGate(src).runGated<String>(300 * _mb, (t) async {
        starts++;
        return 'ok';
      });
      await pump();
      expect(starts, 0);
      src.set(wifi);
      expect(await f, 'ok');
      expect(starts, 1);
    });

    test(
      'runGated: pauses mid-transfer on cellular, keeps progress, resumes on Wi-Fi',
      () async {
        final src = _FakeSource(wifi, DownloadNetworkPreference.wifiOnly);
        var received = 0; // survives pauses, like a .part file
        final startOffsets = <int>[];
        final labels = <String?>[];
        final f = NetworkGate(src).runGated<int>(300 * _mb, (token) async {
          startOffsets.add(received);
          final c = Completer<void>();
          token.whenCancel.then((e) => c.complete());
          // "download" some bytes, then wait to be cancelled or finish
          received += 100;
          if (startOffsets.length == 1) {
            await c.future; // stays in flight until the gate pauses it
            throw DioException(
              requestOptions: RequestOptions(path: ''),
              type: DioExceptionType.cancel,
              error: token.cancelError?.error,
            );
          }
          received += 200;
          return received;
        }, onWaiting: labels.add);
        await pump();
        src.set(cell);
        await pump();
        expect(labels.last, 'Waiting for Wi-Fi');
        expect(startOffsets, [0]);
        src.set(wifi);
        expect(await f, 400);
        expect(startOffsets, [0, 100]); // resumed from kept progress
      },
    );

    test('runGated: a user cancel is not swallowed', () async {
      final src = _FakeSource(wifi, DownloadNetworkPreference.wifiOnly);
      final user = CancelToken();
      final f = NetworkGate(src).runGated<int>(300 * _mb, (token) async {
        user.cancel('user');
        await token.whenCancel;
        throw DioException(
          requestOptions: RequestOptions(path: ''),
          type: DioExceptionType.cancel,
          error: token.cancelError?.error,
        );
      }, userCancel: user);
      await expectLater(f, throwsA(isA<DioException>()));
    });

    test('runGated: unrestricted users are never paused', () async {
      final src = _FakeSource(wifi, DownloadNetworkPreference.wifiAndCellular);
      var starts = 0;
      final f = NetworkGate(src).runGated<int>(300 * _mb, (token) async {
        starts++;
        src.set(cell);
        await pump();
        expect(token.isCancelled, isFalse);
        return 1;
      });
      expect(await f, 1);
      expect(starts, 1);
    });
  });
}
