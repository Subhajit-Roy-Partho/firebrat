/// Turns a finished casting (who speaks which quote, with what emotion) plus
/// the voice assignment into the ordered lines a speech engine must voice for
/// one page, and into the package's `cast` manifest record.
library;

import 'cast_models.dart';
import 'cast_segmenter.dart';
import 'cast_voices.dart';

/// One continuous stretch of speech in one voice.
class PlannedLine {
  final String text;
  final String speakerId; // character id or 'narrator'
  final String voice;
  final double speedMul;
  final double semitones;
  final Delivery delivery;
  const PlannedLine(this.text, this.speakerId, this.voice, this.speedMul, this.semitones, this.delivery);
  bool get isNarration => speakerId == kNarratorId;
}

class CastPlan {
  final CastResult cast;
  final Map<String, VoiceAssignment> voices;
  final String narratorVoice;
  final String engine;
  final Map<(int, int), CastUtterance> _byKey;
  final Map<String, CastCharacter> _characters;

  CastPlan({required this.cast, required this.voices, required this.narratorVoice, required this.engine})
      : _byKey = {for (final u in cast.utterances) (u.page, u.idx): u},
        _characters = {for (final c in cast.characters) c.id: c};

  /// Lines to voice for [text] of [page]. Narration spans that follow each other
  /// in the narrator's voice are merged so the engine reads them as one phrase
  /// (neural TTS is weakest on very short snippets such as "said Alice,").
  List<PlannedLine> linesForPage(int page, String text) {
    final mood = cast.pageMood[page];
    final narrationDelivery = narrationDeliveryFor(mood?.emotion);
    final lines = <PlannedLine>[];
    for (final seg in segmentPageText(page, text)) {
      var speaker = kNarratorId;
      var delivery = narrationDelivery;
      if (seg.isQuote) {
        final u = _byKey[(page, seg.idx)];
        if (u != null) {
          speaker = _characters.containsKey(u.speaker) ? u.speaker : kNarratorId;
          // a quote read by the narrator (unknown speaker) still carries its emotion
          delivery = deliveryFor(u.emotion, u.delivery);
        }
      }
      final isNarrator = speaker == kNarratorId;
      final assignment = isNarrator ? null : voices[speaker];
      final voice = assignment?.voice ?? narratorVoice;
      if (lines.isNotEmpty && isNarrator && lines.last.isNarration && !seg.isQuote && lines.last.delivery == narrationDelivery) {
        final prev = lines.removeLast();
        lines.add(PlannedLine(prev.text + seg.text, prev.speakerId, prev.voice, prev.speedMul, prev.semitones, prev.delivery));
        continue;
      }
      lines.add(PlannedLine(seg.text, speaker, voice, assignment?.speedMul ?? 1.0, assignment?.semitones ?? 0.0, delivery));
    }
    return lines;
  }

  /// Manifest `cast` key (same shape as the server pipeline's).
  Map<String, dynamic> toManifestJson() => {
        'engine': engine,
        'narrator': {'voice': narratorVoice, 'accent': cast.narrator.accent},
        'characters': [
          for (final c in cast.characters)
            {
              'id': c.id,
              'name': c.name,
              'gender': c.gender,
              'age': c.age,
              'voice': voices[c.id]?.voice ?? narratorVoice,
            }
        ],
      };

  /// `character_roster.json` in the shape the Cast screen already reads.
  Map<String, dynamic> toRosterJson({int scannedPages = 0}) {
    final lines = <String, int>{};
    final pages = <String, Set<int>>{};
    for (final u in cast.utterances) {
      lines[u.speaker] = (lines[u.speaker] ?? 0) + 1;
      pages.putIfAbsent(u.speaker, () => {}).add(u.page);
    }
    return {
      'mode': 'expressive',
      'scanned_pages': scannedPages,
      'attribution': 'on_device_llm',
      'unknown_speaker': 'narrator',
      'characters': [
        for (final c in cast.characters)
          {
            'id': c.id,
            'name': c.name,
            'evidence_pages': (pages[c.id]?.toList() ?? <int>[])..sort(),
            'style': {'rate': 0.48 * (voices[c.id]?.speedMul ?? 1.0), 'pitch': 1.0, 'voice_index': 0},
            'voice_gender': c.gender,
            'gender_evidence': ['on-device language model'],
            'voice_override': null,
            'traits': {'gender': c.gender, 'age': c.age, 'temperament': c.temperament, 'source': 'llm'},
            'lines': lines[c.id] ?? 0,
          }
      ],
      'assigned_voices': {for (final c in cast.characters) c.name: voices[c.id]?.voice ?? narratorVoice},
      'dialogue': {
        'total': cast.quotesTotal,
        'attributed': cast.utterances.where((u) => u.speaker != kNarratorId).length,
      },
      'voice_engine': engine,
      'research': {
        'status': 'applied',
        'article': 'On-device language model (${cast.llmModel})',
        'described': cast.characters.length,
      },
    };
  }
}
