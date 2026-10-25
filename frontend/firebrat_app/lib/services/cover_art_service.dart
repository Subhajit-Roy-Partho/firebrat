import 'dart:io';
import '../widgets/book_cover.dart';
import 'download_manager.dart';

/// Artwork for the lock screen and media notification when no figure is on
/// screen: the book's own cover if the package ships one, otherwise the same
/// generated cover the library shows. Novels and other text-only sections
/// previously got no image at all.
class CoverArtService {
  final DownloadManager _downloads;
  CoverArtService(this._downloads);

  Future<Uri?> coverUri({
    required String bookId,
    required String title,
    String author = '',
  }) async {
    try {
      final real = await _downloads.coverPath(bookId);
      if (real != null) return Uri.file(real);
      final dir = await _downloads.bookDir(bookId);
      final cached = File('${dir.path}/cover_generated.png');
      if (!await cached.exists()) {
        await cached.writeAsBytes(await renderGeneratedCoverPng(
            bookId: bookId, title: title, author: author));
      }
      return Uri.file(cached.path);
    } catch (_) {
      // Artwork is cosmetic; never let it block playback.
      return null;
    }
  }
}
