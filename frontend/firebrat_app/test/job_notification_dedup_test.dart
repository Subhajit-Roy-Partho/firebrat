import 'package:firebrat_app/models/book.dart';
import 'package:firebrat_app/models/job.dart';
import 'package:firebrat_app/services/api_client.dart';
import 'package:firebrat_app/state/conversions_providers.dart';
import 'package:firebrat_app/state/library_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ConversionJob job(String id, JobState state) => ConversionJob(
      jobId: id,
      bookId: 'book-$id',
      filename: '$id.pdf',
      title: 'Book $id',
      state: state,
      stage: null,
      detail: null,
      progress: null,
      needsReviewCount: 0,
      error: null,
      retryCount: 0,
      createdAt: 'now',
      updatedAt: 'now',
    );

class FakeJobsApi extends ApiClient {
  List<ConversionJob> jobs;
  FakeJobsApi(this.jobs) : super(baseUrl: 'http://localhost:1');

  @override
  Future<List<ConversionJob>> listJobs() async => List.of(jobs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final announced = <String>[];

  setUp(() {
    announced.clear();
    JobsNotifier.announceHook = (title, body) async {
      announced.add('$title|$body');
    };
  });

  tearDown(() {
    JobsNotifier.announceHook = null;
  });

  ProviderContainer makeContainer(FakeJobsApi api) {
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      // Keep the poll side-effects local — no real server in tests.
      localBooksProvider.overrideWith((ref) async => const <BookSummary>[]),
      catalogProvider.overrideWith((ref) async => const <BookSummary>[]),
    ]);
    addTearDown(container.dispose);
    // `jobsProvider` is autoDispose: a bare read would let it dispose
    // immediately (mirroring the closed-screen case). Holding a listener
    // mirrors the open Jobs screen watching it via ref.watch.
    container.listen(jobsProvider, (_, _) {});
    return container;
  }

  Future<void> settle(ProviderContainer c) async {
    // Let the build-triggered _load() plus one explicit refresh finish.
    await c.read(jobsProvider.notifier).refresh();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await c.read(jobsProvider.notifier).refresh();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  test('job already done on first load is silent (no repeat on reopen)', () async {
    SharedPreferences.setMockInitialValues({});
    final container = makeContainer(FakeJobsApi([job('a', JobState.done)]));
    await settle(container);
    expect(announced, isEmpty);
  });

  test('queued -> done transition announces exactly once', () async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeJobsApi([job('b', JobState.queued)]);
    final container = makeContainer(api);
    await settle(container);
    expect(announced, isEmpty);

    api.jobs = [job('b', JobState.done)];
    await container.read(jobsProvider.notifier).refresh();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(announced, hasLength(1));
    expect(announced.single, contains('Conversion finished'));

    // Further polls while still done stay quiet.
    await container.read(jobsProvider.notifier).refresh();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(announced, hasLength(1));

    // The announced id is persisted for the next mount.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(JobsNotifier.notifiedDoneKey), contains('b'));
  });

  test('remount with still-done job does not re-announce (exp-9 fix)', () async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeJobsApi([job('c', JobState.running)]);
    final first = makeContainer(api);
    await settle(first);
    api.jobs = [job('c', JobState.done)];
    await first.read(jobsProvider.notifier).refresh();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(announced, hasLength(1));
    first.dispose();

    // Simulate reopening the Jobs screen: fresh provider, same prefs.
    announced.clear();
    final second = makeContainer(api);
    await settle(second);
    await second.read(jobsProvider.notifier).refresh();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(announced, isEmpty);
    second.dispose();
  });

  test('job already failed on first load is silent; running -> failed announces once', () async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeJobsApi([job('d', JobState.failed)]);
    final container = makeContainer(api);
    await settle(container);
    expect(announced, isEmpty);

    final api2 = FakeJobsApi([job('e', JobState.running)]);
    final container2 = makeContainer(api2);
    await settle(container2);
    expect(announced, isEmpty);
    api2.jobs = [job('e', JobState.failed)];
    await container2.read(jobsProvider.notifier).refresh();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(announced.where((m) => m.contains('Conversion failed')), hasLength(1));
  });
}
