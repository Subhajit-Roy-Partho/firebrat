import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/book.dart';
import '../services/api_client.dart';
import '../utils/server_url.dart';
import 'library_providers.dart';

/// Connection status + book listing for whatever server URL is currently
/// saved (`conversionModeProvider.cloudServerUrl`, via `apiClientProvider`)
/// — drives the Conversion settings screen's "is this server reachable,
/// what's already converted there, delete to free space" section.
///
/// Also carries the server's conversion model catalog (probed from
/// GET /models with a GET /settings fallback): the settings screen's model
/// dropdown reads this, and an empty list means "probe failed, let the
/// user type a name instead".
class ServerConnectionState {
  final bool checking;
  final bool? connected; // null = not checked yet this session
  final List<BookSummary> books;
  final String? error;
  final List<String> models;
  final bool modelsLoading;
  final String? modelsError;

  const ServerConnectionState({
    this.checking = false,
    this.connected,
    this.books = const [],
    this.error,
    this.models = const [],
    this.modelsLoading = false,
    this.modelsError,
  });

  ServerConnectionState copyWith({
    bool? checking,
    bool? connected,
    List<BookSummary>? books,
    String? error,
    List<String>? models,
    bool? modelsLoading,
    String? modelsError,
  }) =>
      ServerConnectionState(
        checking: checking ?? this.checking,
        connected: connected ?? this.connected,
        books: books ?? this.books,
        error: error ?? this.error,
        models: models ?? this.models,
        modelsLoading: modelsLoading ?? this.modelsLoading,
        modelsError: modelsError ?? this.modelsError,
      );
}

class ServerBooksNotifier extends Notifier<ServerConnectionState> {
  @override
  ServerConnectionState build() => const ServerConnectionState();

  Future<void> check() async {
    state = const ServerConnectionState(
      checking: true,
      models: [],
      modelsLoading: false,
    );
    final api = ref.read(apiClientProvider);
    final reachable = await api.checkHealth();
    if (!reachable) {
      state = const ServerConnectionState(checking: false, connected: false, error: 'Could not reach this server.');
      return;
    }
    try {
      final books = await api.listBooks();
      state = ServerConnectionState(checking: false, connected: true, books: books, models: state.models);
      unawaitedRefreshModels();
    } catch (e) {
      state = ServerConnectionState(connected: true, error: 'Connected, but could not list books: $e');
    }
  }

  void unawaitedRefreshModels() {
    // Fire-and-forget from check(): the book list shouldn't wait on it.
    refreshModels();
  }

  /// Probes the server's model catalog. When [baseUrlOverride] is given
  /// (the URL field's current text, possibly unsaved), the probe goes
  /// there instead of the saved URL — so the dropdown fills in before
  /// the user hits Save.
  Future<void> refreshModels({String? baseUrlOverride}) async {
    state = state.copyWith(modelsLoading: true, modelsError: null);
    try {
      final ApiClient api;
      if (baseUrlOverride != null && baseUrlOverride.trim().isNotEmpty) {
        api = ApiClient(baseUrl: normalizeServerUrl(baseUrlOverride));
      } else {
        api = ref.read(apiClientProvider);
      }
      final models = await api.getModels();
      if (models.isEmpty) {
        state = state.copyWith(
          modelsLoading: false,
          models: const [],
          modelsError: 'Server listed no models — type a name instead.',
        );
      } else {
        state = state.copyWith(modelsLoading: false, models: models, modelsError: null);
      }
    } catch (e) {
      state = state.copyWith(
        modelsLoading: false,
        models: const [],
        modelsError: 'Could not load models: $e',
      );
    }
  }

  Future<void> deleteBook(String bookId) async {
    final api = ref.read(apiClientProvider);
    await api.deleteBook(bookId);
    await check();
  }
}

final serverBooksProvider = NotifierProvider<ServerBooksNotifier, ServerConnectionState>(ServerBooksNotifier.new);
