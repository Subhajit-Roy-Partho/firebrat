import 'package:dio/dio.dart';
import 'package:firebrat_app/models/job.dart';
import 'package:firebrat_app/models/manifest.dart';
import 'package:firebrat_app/services/api_client.dart';
import 'package:firebrat_app/state/on_device_conversion_providers.dart';
import 'package:firebrat_app/state/server_books_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('contentMode accepts cast and rejects unknown modes', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // Baseline round-trips through prefs.
    await container
        .read(conversionModeProvider.notifier)
        .setContentMode('cast');
    expect(container.read(conversionModeProvider).contentMode, 'cast');
    expect(
      (await SharedPreferences.getInstance()).getString(
        'conversion.contentMode',
      ),
      'cast',
    );
    // Existing modes still work.
    await container
        .read(conversionModeProvider.notifier)
        .setContentMode('novel');
    expect(container.read(conversionModeProvider).contentMode, 'novel');
    // Bogus modes still throw and leave state alone.
    await expectLater(
      container.read(conversionModeProvider.notifier).setContentMode('bogus'),
      throwsArgumentError,
    );
    expect(container.read(conversionModeProvider).contentMode, 'novel');
  });

  test('castAvailable defaults false and survives copyWith', () {
    const empty = ServerConnectionState();
    expect(empty.castAvailable, isFalse);
    expect(empty.copyWith().castAvailable, isFalse);
    expect(empty.copyWith(castAvailable: true).castAvailable, isTrue);
    // Other fields still copy through alongside the new flag.
    expect(empty.copyWith(models: const ['m'], castAvailable: true).models, [
      'm',
    ]);
  });

  test('friendlyUploadError surfaces the server 400 for disabled cast', () {
    RequestOptions req() => RequestOptions(path: '/books/upload');
    final disabled = DioException(
      requestOptions: req(),
      response: Response(
        requestOptions: req(),
        statusCode: 400,
        data: {'detail': 'Expressive voices are not enabled on this server'},
      ),
      type: DioExceptionType.badResponse,
    );
    expect(
      ApiClient.friendlyUploadError(disabled),
      'Expressive voices are not enabled on this server',
    );
    // Non-cast errors keep their detail; unknown shapes fall back to $e.
    final other = DioException(
      requestOptions: req(),
      response: Response(
        requestOptions: req(),
        statusCode: 500,
        data: {'detail': 'boom'},
      ),
      type: DioExceptionType.badResponse,
    );
    expect(ApiClient.friendlyUploadError(other), contains('boom'));
    expect(
      ApiClient.friendlyUploadError(StateError('nope')),
      contains('Upload failed'),
    );
  });

  test(
    'Manifest.fromJson ignores the additive cast key and qwen3-tts engine',
    () {
      final manifest = Manifest.fromJson({
        'book_id': 'b',
        'title': 'T',
        'sections': const [],
        // Additive firebrat_cast payload: unknown keys must not break parsing.
        'cast': {
          'engine': 'qwen3-tts',
          'characters': [
            {
              'id': 'c1',
              'name': 'Jane',
              'gender': 'f',
              'age': 'adult',
              'voice_description': 'warm',
            },
          ],
        },
        'narrator_voice': {'engine': 'qwen3-tts'},
      });
      expect(manifest.bookId, 'b');
      expect(manifest.sections, isEmpty);
    },
  );

  test('ConversionJob.fromJson passes cast stage text through', () {
    ConversionJob jobFor(String stage) => ConversionJob.fromJson({
      'job_id': 'j',
      'book_id': 'b',
      'filename': 'book.epub',
      'title': 'Book',
      'state': 'running',
      'stage': stage,
      'detail': null,
      'progress': 0.1,
      'needs_review_count': 0,
      'error': null,
      'retry_count': 0,
      'created_at': 'now',
      'updated_at': 'now',
    });
    // Every firebrat_cast stage string must survive the model (the job card
    // labels them; unlisted stages must still render, never crash).
    for (final stage in [
      'queued',
      'preparing text',
      'casting characters',
      'recording voices',
      'packaging',
    ]) {
      expect(jobFor(stage).stage, stage);
    }
  });
}
