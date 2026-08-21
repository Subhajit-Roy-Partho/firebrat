/// Lightweight catalog entry returned by GET /books — used for the library
/// screen before a book's full manifest is downloaded.
class BookSummary {
  final String bookId;
  final String title;
  final String author;
  final int totalDurationMs;
  final int sectionCount;
  final int sizeBytes;
  final String updatedAt;

  const BookSummary({
    required this.bookId,
    required this.title,
    required this.author,
    required this.totalDurationMs,
    required this.sectionCount,
    required this.sizeBytes,
    required this.updatedAt,
  });

  factory BookSummary.fromJson(Map<String, dynamic> json) => BookSummary(
        bookId: json['book_id'] as String,
        title: json['title'] as String,
        author: json['author'] as String? ?? '',
        totalDurationMs: json['total_duration_ms'] as int? ?? 0,
        sectionCount: json['section_count'] as int? ?? 0,
        sizeBytes: json['size_bytes'] as int? ?? 0,
        updatedAt: json['updated_at'] as String? ?? '',
      );
}
