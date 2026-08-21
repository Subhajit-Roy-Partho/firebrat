import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/book.dart';
import '../services/api_client.dart';
import '../services/download_manager.dart';
import '../services/library_repository.dart';

/// Point this at the machine running the FastAPI backend (uvicorn server.main:app).
/// Override at build time with --dart-define=FIREBRAT_API_BASE_URL=http://host:8000
/// if the default doesn't match your setup.
const _defaultApiBaseUrl = String.fromEnvironment(
  'FIREBRAT_API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8000',
);

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(baseUrl: _defaultApiBaseUrl));

final downloadManagerProvider =
    Provider<DownloadManager>((ref) => DownloadManager(ref.watch(apiClientProvider)));

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(ref.watch(apiClientProvider), ref.watch(downloadManagerProvider)),
);

final catalogProvider = FutureProvider<List<BookSummary>>((ref) async {
  final repo = ref.watch(libraryRepositoryProvider);
  return repo.fetchCatalog();
});

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

/// Which book_ids are already downloaded on-device. Refresh after a download completes.
final downloadedBooksProvider = FutureProvider<Set<String>>((ref) async {
  final dm = ref.watch(downloadManagerProvider);
  final catalog = await ref.watch(catalogProvider.future);
  final result = <String>{};
  for (final b in catalog) {
    if (await dm.isDownloaded(b.bookId)) result.add(b.bookId);
  }
  return result;
});
