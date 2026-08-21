import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/book.dart';
import '../services/api_client.dart';
import '../services/download_manager.dart';
import '../services/import_manager.dart';
import '../services/library_repository.dart';

/// Point this at the machine running the FastAPI backend (uvicorn server.main:app).
/// Override at build time with --dart-define=FIREBRAT_API_BASE_URL=http://host:8000
/// if the default doesn't match your setup. A server is entirely optional —
/// books imported from a local file work with this never being reachable.
const _defaultApiBaseUrl = String.fromEnvironment(
  'FIREBRAT_API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8000',
);

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(baseUrl: _defaultApiBaseUrl));

final downloadManagerProvider =
    Provider<DownloadManager>((ref) => DownloadManager(ref.watch(apiClientProvider)));

final importManagerProvider =
    Provider<ImportManager>((ref) => ImportManager(ref.watch(downloadManagerProvider)));

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(ref.watch(apiClientProvider), ref.watch(downloadManagerProvider)),
);

/// The remote catalog. Errors (server unreachable, no server at all) are
/// expected and normal here — the library screen treats a failed catalog
/// fetch as "no books available to download," not a hard error, since
/// locally-imported books are a fully independent path.
final catalogProvider = FutureProvider<List<BookSummary>>((ref) async {
  final repo = ref.watch(libraryRepositoryProvider);
  return repo.fetchCatalog();
});

/// Every book already usable on-device right now — downloaded or imported.
/// This is the library screen's primary data source.
final localBooksProvider = FutureProvider<List<BookSummary>>((ref) async {
  final repo = ref.watch(libraryRepositoryProvider);
  return repo.listLocalBooks();
});

void invalidateLibrary(WidgetRef ref) {
  ref.invalidate(localBooksProvider);
  ref.invalidate(catalogProvider);
}

/// Tracks in-progress download percentage per book_id (0.0-1.0), absent = not downloading.
class DownloadProgressNotifier extends Notifier<Map<String, double>> {
  @override
  Map<String, double> build() => {};

  void setProgress(String bookId, double p) {
    state = {...state, bookId: p};
  }

  void clear(String bookId) {
    final next = {...state}..remove(bookId);
    state = next;
  }
}

final downloadProgressProvider =
    NotifierProvider<DownloadProgressNotifier, Map<String, double>>(DownloadProgressNotifier.new);

/// True while a local-file import is being extracted.
class ImportInProgressNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

final importInProgressProvider =
    NotifierProvider<ImportInProgressNotifier, bool>(ImportInProgressNotifier.new);
