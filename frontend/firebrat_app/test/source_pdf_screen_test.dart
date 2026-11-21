import 'dart:async';
import 'package:firebrat_app/models/manifest.dart';
import 'package:firebrat_app/services/playback_controller.dart';
import 'package:firebrat_app/state/reader_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:firebrat_app/screens/source_pdf_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _PdfPlayer extends Fake implements PlaybackController {
  final changes = StreamController<PlayerState>.broadcast();
  bool playing = true;
  @override
  bool get isPlaying => playing;
  @override
  Stream<PlayerState> get playerStateStream => changes.stream;
  @override
  Future<void> play() async {
    playing = true;
    changes.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async {
    playing = false;
    changes.add(PlayerState(false, ProcessingState.ready));
  }
}

class _PdfReader extends ReaderController {
  final bool loading;
  _PdfReader({this.loading = false}) : super('pdf');
  final fakePlayer = _PdfPlayer();
  int? get sectionIndex => state?.sectionIndex;
  @override
  ReaderState build() {
    player = fakePlayer;
    ref.onDispose(() => fakePlayer.changes.close());
    return ReaderState(
      manifest: Manifest.fromJson({
        'book_id': 'pdf',
        'title': 'Textbook',
        'sections': [
          for (var i = 0; i < 2; i++)
            {
              'section_id': 'sec_$i',
              'order': i,
              'title': 'Section $i',
              'audio_path': 'audio',
              'segments_path': 'segments',
            },
        ],
      }),
      sectionIndex: 0,
      activeSegment: null,
      loadingSection: loading,
    );
  }

  @override
  Future<void> nextSection() async {
    state = state!.copyWith(sectionIndex: 1);
  }

  @override
  Future<void> previousSection() async {
    state = state!.copyWith(sectionIndex: 0);
  }
}

void main() {
  testWidgets(
    'PDF transport follows live playback and skips sections with boundary guards',
    (tester) async {
      final reader = _PdfReader();
      var jumps = 0;
      var selections = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            readerControllerProvider('pdf').overrideWith(() => reader),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SourcePdfTransport(
                bookId: 'pdf',
                onJump: () => jumps++,
                onSelectImage: () => selections++,
              ),
            ),
          ),
        ),
      );
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == 'Previous section')).onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();
      expect(reader.fakePlayer.playing, isFalse);
      expect(find.byTooltip('Play'), findsOneWidget);
      await tester.tap(find.byTooltip('Play'));
      await tester.tap(find.byTooltip('Jump to current section'));
      await tester.tap(find.byTooltip('Select image from PDF'));
      expect(jumps, 1);
      expect(selections, 1);
      await tester.tap(find.byTooltip('Next section'));
      await tester.pump();
      expect(reader.sectionIndex, 1);
      expect(
        tester.widget<IconButton>(find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == 'Next section')).onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Previous section'));
      await tester.pump();
      expect(reader.sectionIndex, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('PDF playback controls are disabled while a section loads', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          readerControllerProvider(
            'pdf',
          ).overrideWith(() => _PdfReader(loading: true)),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SourcePdfTransport(bookId: 'pdf')),
        ),
      ),
    );
    for (final tooltip in ['Pause', 'Previous section', 'Next section']) {
      expect(
        tester.widget<IconButton>(find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == tooltip)).onPressed,
        isNull,
      );
    }
    await tester.pumpWidget(const SizedBox());
  });

  for (final sample in [
    (100, 0, 1.0),
    (100, 8, 8.0),
    (0, 8, 1.0),
    (100, 1, 1.0),
  ]) {
    testWidgets(
      'PDF page ${sample.$1} with count ${sample.$2} stays in slider bounds',
      (tester) async {
        int? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SourcePdfPageSlider(
                currentPage: sample.$1,
                pageCount: sample.$2,
                onPageSelected: (value) => selected = value,
              ),
            ),
          ),
        );
        final slider = tester.widget<Slider>(find.byType(Slider));
        expect(tester.takeException(), isNull);
        expect(slider.value, sample.$3);
        if (sample.$2 <= 1) {
          expect(slider.onChanged, isNull);
        } else {
          slider.onChanged!(3);
          expect(selected, 3);
        }
      },
    );
  }
}
