import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/book.dart';
import 'library_providers.dart';

/// Connection status + book listing for whatever server URL is currently
/// saved (`conversionModeProvider.cloudServerUrl`, via `apiClientProvider`)
/// — drives the Conversion settings screen's "is this server reachable,
/// what's already converted there, delete to free space" section.
class ServerConnectionState {
  final bool checking;
  final bool? connected; // null = not checked yet this session
  final List<BookSummary> books;
  final String? error;

  const ServerConnectionState({this.checking = false, this.connected, this.books = const [], this.error});
}

class ServerBooksNotifier extends Notifier<ServerConnectionState> {
  @override
  ServerConnectionState build() => const ServerConnectionState();

  Future<void> check() async {
    state = const ServerConnectionState(checking: true);
    final api = ref.read(apiClientProvider);
    final reachable = await api.checkHealth();
    if (!reachable) {
      state = const ServerConnectionState(checking: false, connected: false, error: 'Could not reach this server.');
      return;
    }
    try {
      final books = await api.listBooks();
      state = ServerConnectionState(checking: false, connected: true, books: books);
    } catch (e) {
      state = ServerConnectionState(connected: true, error: 'Connected, but could not list books: $e');
    }
  }

  Future<void> deleteBook(String bookId) async {
    final api = ref.read(apiClientProvider);
    await api.deleteBook(bookId);
    await check();
  }
}

final serverBooksProvider = NotifierProvider<ServerBooksNotifier, ServerConnectionState>(ServerBooksNotifier.new);
