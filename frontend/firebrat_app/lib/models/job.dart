/// One upload's conversion job, as returned by the server's job endpoints
/// (POST /books/upload, GET /jobs, GET /jobs/{id}, POST /jobs/{id}/retry).
enum JobState { queued, running, done, failed }

JobState jobStateFromString(String s) => switch (s) {
      'queued' => JobState.queued,
      'running' => JobState.running,
      'done' => JobState.done,
      'failed' => JobState.failed,
      _ => JobState.queued,
    };

class ConversionJob {
  final String jobId;
  final String bookId;
  final String filename;
  final String title;
  final JobState state;
  final String? stage; // extracting | compiling | rendering_formulas | synthesizing | packaging | done
  final String? detail;
  final double? progress; // 0.0-1.0, stage-relative
  final int needsReviewCount;
  final String? error;
  final int retryCount;
  final String createdAt;
  final String updatedAt;

  const ConversionJob({
    required this.jobId,
    required this.bookId,
    required this.filename,
    required this.title,
    required this.state,
    required this.stage,
    required this.detail,
    required this.progress,
    required this.needsReviewCount,
    required this.error,
    required this.retryCount,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isActive => state == JobState.queued || state == JobState.running;
  bool get isRetryable => state == JobState.failed || state == JobState.done;

  factory ConversionJob.fromJson(Map<String, dynamic> json) => ConversionJob(
        jobId: json['job_id'] as String,
        bookId: json['book_id'] as String,
        filename: json['filename'] as String,
        title: json['title'] as String,
        state: jobStateFromString(json['state'] as String),
        stage: json['stage'] as String?,
        detail: json['detail'] as String?,
        progress: (json['progress'] as num?)?.toDouble(),
        needsReviewCount: json['needs_review_count'] as int? ?? 0,
        error: json['error'] as String?,
        retryCount: json['retry_count'] as int? ?? 0,
        createdAt: json['created_at'] as String,
        updatedAt: json['updated_at'] as String,
      );
}
