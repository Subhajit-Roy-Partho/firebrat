import 'package:firebrat_app/models/book.dart';
import 'package:firebrat_app/services/library_repository.dart';
import 'package:firebrat_app/state/library_providers.dart';
import 'package:firebrat_app/state/on_device_conversion_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingRepository implements LibraryRepository {
  int requests = 0;
  @override
  Future<List<BookSummary>> fetchCatalog() async {
    requests++;
    return [];
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('offline is the persisted default and never requests the server catalog', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = _CountingRepository();
    final container = ProviderContainer(overrides: [
      libraryRepositoryProvider.overrideWithValue(repo),
    ]);
    addTearDown(container.dispose);
    expect(container.read(conversionModeProvider).mode, ConversionModePref.offline);
    expect(await container.read(catalogProvider.future), isEmpty);
    expect(repo.requests, 0);

    await container.read(conversionModeProvider.notifier).setMode(ConversionModePref.cloud);
    await container.read(catalogProvider.future);
    expect(repo.requests, 1);
    await container.read(conversionModeProvider.notifier).setMode(ConversionModePref.offline);
    await container.read(catalogProvider.future);
    expect(repo.requests, 1);
    expect((await SharedPreferences.getInstance()).getString('conversion.mode'), 'offline');
  });

  test('novel mode needs no cloud configuration and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(conversionModeProvider);
    await Future<void>.delayed(Duration.zero);
    await container.read(conversionModeProvider.notifier).setContentMode('novel');
    final settings = container.read(conversionModeProvider);
    expect(settings.isOnDeviceConfigured, isTrue);
    expect(settings.allowCloudFallback, isFalse);
    expect((await SharedPreferences.getInstance()).getString('conversion.contentMode'), 'novel');
  });

  for (final mode in ConversionModePref.values) {
    test('restores saved ${mode.name} mode', () async {
      SharedPreferences.setMockInitialValues({'conversion.mode': mode.name});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(conversionModeProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(conversionModeProvider).mode, mode);
    });
  }
}
