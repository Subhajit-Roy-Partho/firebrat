import 'dart:async';
import 'package:firebrat_app/screens/conversion_detail_screen.dart';
import 'package:firebrat_app/screens/conversions_screen.dart';
import 'package:firebrat_app/state/on_device_pipeline_run_provider.dart';
import 'package:firebrat_app/state/on_device_queue_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Fake {
  Future<String> run(ProviderContainer c, List<String> paths, {String? titleOverride}) =>
      Completer<String>().future; // never finishes: the book stays "running"
}

void main() {
  test('steps and the activity log follow the reports', () {
    final steps = conversionSteps(novel: true);
    expect(steps.map((s) => s.key), ['extracting', 'compiling', 'synthesizing', 'done']);
    expect(stepIndexFor('synthesizing', steps), 2);
    expect(stepIndexFor('starting', steps), -1);
    expect(formatDuration(const Duration(seconds: 75)), '1m 15s');
    expect(formatDuration(const Duration(minutes: 125)), '2h 5m');

    var s = const OnDeviceRunState();
    s = s.next(stage: 'extracting', detail: 'reading ebook text', fraction: .1);
    s = s.next(stage: 'extracting', detail: 'reading ebook text', fraction: .2); // same message: not logged twice
    s = s.next(stage: 'synthesizing', detail: '3/48 sections', fraction: .06);
    expect(s.events.map((e) => e.detail), ['reading ebook text', '3/48 sections']);
    expect(s.stage, 'synthesizing');
    expect(s.fraction, .06);
    expect(s.startedAt, isNotNull);
  });

  testWidgets('tapping a book shows done, running and remaining steps with progress', (tester) async {
    SharedPreferences.setMockInitialValues({'conversion.mode': 'onDevice', 'conversion.contentMode': 'novel'});
    tester.view.physicalSize = const Size(1080, 3200); // tall enough for the whole (lazy) list
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final fake = _Fake();
    final container = ProviderContainer(overrides: [
      conversionRunnerProvider.overrideWithValue(fake.run),
      conversionCancellerProvider.overrideWithValue((c) async {}),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const MaterialApp(home: ConversionsScreen())));
    await tester.pump(const Duration(milliseconds: 200));
    container.read(onDeviceQueueProvider.notifier).enqueue(['/x/First.pdf', '/x/Second.pdf']);
    await tester.pump(const Duration(milliseconds: 200));
    container.read(onDeviceRunProvider.notifier).set(const OnDeviceRunState(stage: 'starting', detail: 'preparing')
        .next(stage: 'extracting', detail: 'reading ebook text', fraction: .5)
        .next(stage: 'synthesizing', detail: '12/48 sections', fraction: .25));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(ValueKey('queue-${container.read(onDeviceQueueProvider)[0].id}')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1)); // page transition
    expect(find.text('Converting now'), findsOneWidget);
    expect(find.textContaining('Reading the book · Done'), findsOneWidget);
    expect(find.textContaining('Preparing the text · Done'), findsOneWidget);
    expect(find.textContaining('Recording the narration · Running now'), findsOneWidget);
    expect(find.text('12/48 sections'), findsWidgets);
    expect(find.textContaining('Finishing up · Still to do'), findsOneWidget);
    expect(find.textContaining('left in this step'), findsOneWidget);
    expect(find.textContaining('reading ebook text'), findsWidgets); // in the activity log

    // A waiting book shows its place in the queue and every step still to do.
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(ValueKey('queue-${container.read(onDeviceQueueProvider)[1].id}')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1)); // page transition
    expect(find.text('Next in the queue'), findsOneWidget);
    expect(find.textContaining('Still to do'), findsNWidgets(4));
  });
}
