import 'dart:async';
import 'package:firebrat_app/screens/conversions_screen.dart';
import 'package:firebrat_app/state/battery_provider.dart';
import 'package:firebrat_app/state/on_device_pipeline_run_provider.dart';
import 'package:firebrat_app/state/on_device_queue_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A runner the test controls: each started book waits on its own completer.
class FakeRunner {
  final started = <String>[];
  final waiting = <String, Completer<String>>{};
  int cancels = 0;
  int pauses = 0;

  Future<String> run(ProviderContainer c, List<String> paths, {String? titleOverride}) {
    final key = titleOverride ?? paths.first;
    started.add(key);
    return (waiting[key] = Completer<String>()).future;
  }

  Future<void> cancel(ProviderContainer c, {bool keepProgress = false}) async {
    if (keepProgress) {
      pauses++;
    } else {
      cancels++;
    }
    final last = started.last;
    waiting[last]!.completeError(ConversionCancelled());
  }
}

ProviderContainer makeContainer(FakeRunner fake, {Future<List<String>> Function(String)? unzip}) {
  final c = ProviderContainer(overrides: [
    conversionRunnerProvider.overrideWithValue(fake.run),
    conversionCancellerProvider.overrideWithValue(fake.cancel),
    if (unzip != null) unzipChaptersProvider.overrideWithValue(unzip),
  ]);
  addTearDown(c.dispose);
  return c;
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));
List<QueueStatus> statuses(ProviderContainer c) => [for (final i in c.read(onDeviceQueueProvider)) i.status];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('books convert one at a time, in the order they were added', () async {
    final fake = FakeRunner();
    final c = makeContainer(fake);
    c.read(onDeviceQueueProvider.notifier).enqueue(['/books/A.pdf', '/books/B.epub', '/books/C.azw3']);
    await settle();
    expect(fake.started, ['A']); // only the first has started
    expect(statuses(c), [QueueStatus.running, QueueStatus.queued, QueueStatus.queued]);
    fake.waiting['A']!.complete('a');
    await settle();
    expect(fake.started, ['A', 'B']);
    fake.waiting['B']!.complete('b');
    await settle();
    fake.waiting['C']!.complete('c');
    await settle();
    expect(statuses(c), [QueueStatus.done, QueueStatus.done, QueueStatus.done]);
  });

  test('a failed book is recorded and does not block the next one', () async {
    final fake = FakeRunner();
    final c = makeContainer(fake);
    c.read(onDeviceQueueProvider.notifier).enqueue(['/x/Bad.pdf', '/x/Good.pdf']);
    await settle();
    fake.waiting['Bad']!.completeError(StateError('Could not read source page 1'));
    await settle();
    final items = c.read(onDeviceQueueProvider);
    expect(items.first.status, QueueStatus.failed);
    expect(items.first.error, contains('Could not read source page 1'));
    expect(fake.started, ['Bad', 'Good']);
  });

  test('stopping the current book cancels it and carries on with the next', () async {
    final fake = FakeRunner();
    final c = makeContainer(fake);
    final queue = c.read(onDeviceQueueProvider.notifier);
    queue.enqueue(['/x/One.pdf', '/x/Two.pdf']);
    await settle();
    await queue.stopCurrent();
    await settle();
    expect(fake.cancels, 1);
    expect(statuses(c), [QueueStatus.cancelled, QueueStatus.running]);
    expect(fake.started, ['One', 'Two']);
  });

  test('a waiting book can be removed; the running one cannot be removed, only stopped', () async {
    final fake = FakeRunner();
    final c = makeContainer(fake);
    final queue = c.read(onDeviceQueueProvider.notifier);
    queue.enqueue(['/x/One.pdf', '/x/Two.pdf', '/x/Three.pdf']);
    await settle();
    final items = c.read(onDeviceQueueProvider);
    queue.remove(items[1].id);
    queue.remove(items[0].id); // running: ignored
    expect([for (final i in c.read(onDeviceQueueProvider)) i.title], ['One', 'Three']);
    fake.waiting['One']!.complete('x');
    await settle();
    expect(fake.started, ['One', 'Three']); // Two was removed before it started
    queue.clearFinished();
    expect([for (final i in c.read(onDeviceQueueProvider)) i.title], ['Three']);
  });

  test('a zip of chapters is unpacked when its turn comes and named after the zip', () async {
    final fake = FakeRunner();
    final unzipped = <String>[];
    final c = makeContainer(fake, unzip: (zip) async {
      unzipped.add(zip);
      return ['/tmp/ch1.pdf', '/tmp/ch2.pdf'];
    });
    c.read(onDeviceQueueProvider.notifier).enqueue(['/x/My Book.zip']);
    await settle();
    expect(unzipped, ['/x/My Book.zip']);
    expect(fake.started, ['My Book']);
  });

  test('waiting books survive an app restart; finished ones do not', () async {
    final fake = FakeRunner();
    final first = makeContainer(fake);
    first.read(onDeviceQueueProvider.notifier).enqueue(['/x/Done.pdf', '/x/Waiting.pdf']);
    await settle();
    fake.waiting['Done']!.complete('d');
    await settle(); // Waiting is now running
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('onDeviceQueue.pending'), allOf(contains('Waiting'), isNot(contains('Done'))));

    final fake2 = FakeRunner();
    final second = makeContainer(fake2);
    second.read(onDeviceQueueProvider);
    await settle();
    await settle();
    expect(fake2.started, ['Waiting']); // restored and started again
  });

  test('pausing keeps the book and holds the queue until it is resumed', () async {
    final fake = FakeRunner();
    final c = makeContainer(fake);
    final queue = c.read(onDeviceQueueProvider.notifier);
    queue.enqueue(['/x/One.pdf', '/x/Two.pdf']);
    await settle();
    await queue.pauseCurrent();
    await settle();
    expect(fake.pauses, 1);
    expect(fake.cancels, 0);
    expect(statuses(c), [QueueStatus.paused, QueueStatus.queued]);
    expect(fake.started, ['One']); // Two does not start while paused
    queue.resume(c.read(onDeviceQueueProvider).first.id);
    await settle();
    expect(statuses(c), [QueueStatus.running, QueueStatus.queued]);
    expect(fake.started, ['One', 'One']); // runs again; the converter picks up its saved progress
    fake.waiting['One']!.complete('one');
    await settle();
    expect(fake.started, ['One', 'One', 'Two']);
  });

  test('a stopped or failed book can be resumed', () async {
    final fake = FakeRunner();
    final c = makeContainer(fake);
    final queue = c.read(onDeviceQueueProvider.notifier);
    queue.enqueue(['/x/Bad.pdf']);
    await settle();
    fake.waiting['Bad']!.completeError(StateError('boom'));
    await settle();
    expect(statuses(c), [QueueStatus.failed]);
    queue.resume(c.read(onDeviceQueueProvider).first.id);
    await settle();
    expect(statuses(c), [QueueStatus.running]);
  });

  test('a paused book survives the app being closed and stays paused', () async {
    final fake = FakeRunner();
    final c = makeContainer(fake);
    final queue = c.read(onDeviceQueueProvider.notifier);
    queue.enqueue(['/x/Held.pdf']);
    await settle();
    await queue.pauseCurrent();
    await settle();
    final fake2 = FakeRunner();
    final second = makeContainer(fake2);
    second.read(onDeviceQueueProvider);
    await settle();
    await settle();
    expect(statuses(second), [QueueStatus.paused]);
    expect(fake2.started, isEmpty);
  });

  testWidgets('Conversions screen shows the queue, a Stop button and a battery notice', (tester) async {
    SharedPreferences.setMockInitialValues({'conversion.mode': 'onDevice'});
    final fake = FakeRunner();
    final container = ProviderContainer(overrides: [
      conversionRunnerProvider.overrideWithValue(fake.run),
      conversionCancellerProvider.overrideWithValue(fake.cancel),
      batteryUnrestrictedProvider.overrideWith((ref) async => false),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const MaterialApp(home: ConversionsScreen())));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('battery-notice')), findsNothing); // nothing converting yet
    container.read(onDeviceQueueProvider.notifier).enqueue(['/x/First.pdf', '/x/Second.pdf']);
    container.read(onDeviceRunProvider.notifier).set(const OnDeviceRunState(stage: 'extracting', detail: 'reading'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // let the async battery check resolve
    }
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);
    expect(find.byKey(const ValueKey('battery-notice')), findsOneWidget);
    expect(find.text('Open battery settings'), findsOneWidget);
    expect(find.text('Add to queue'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Stop'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(fake.cancels, 1);
    expect(find.text('Stopped'), findsOneWidget);
  });
}
