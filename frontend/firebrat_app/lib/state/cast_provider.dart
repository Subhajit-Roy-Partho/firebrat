import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'library_providers.dart';

/// One speaker found in a novel, as recorded in the book's
/// `character_roster.json` (written on the phone and by the server).
class CastCharacter {
  final String name;
  final int lines;
  final int pagesSeen;
  final int? firstPage; // 1-based
  final String gender; // male | female | unknown
  final String age;
  final String temperament;
  final String traitSource; // web | user | none
  final String voice; // human-readable voice / delivery
  const CastCharacter({
    required this.name,
    required this.lines,
    required this.pagesSeen,
    required this.firstPage,
    required this.gender,
    required this.age,
    required this.temperament,
    required this.traitSource,
    required this.voice,
  });
}

class CastData {
  final List<CastCharacter> characters;
  final int dialogueTotal;
  final int dialogueAttributed;
  final String? researchStatus; // applied | skipped | null (not attempted)
  final String? researchReason;
  final List<String> articles;
  final int described;
  final List<String> notDescribed;
  final List<String> unmatchedOverrides;
  final int? scannedPages;

  const CastData({
    required this.characters,
    required this.dialogueTotal,
    required this.dialogueAttributed,
    this.researchStatus,
    this.researchReason,
    this.articles = const [],
    this.described = 0,
    this.notDescribed = const [],
    this.unmatchedOverrides = const [],
    this.scannedPages,
  });

  /// Share of quoted lines a named speaker was found for (0 to 1).
  double get coverage => dialogueTotal == 0 ? 0 : dialogueAttributed / dialogueTotal;

  /// Builds the cast from a manifest `cast` key (`{engine, narrator, characters:[{id,name,gender,age,voice}]}`);
  /// null when the manifest has none. Line counts are not recorded there.
  static CastData? fromManifestCast(Object? cast) {
    if (cast is! Map || cast['characters'] is! List) return null;
    final list = <CastCharacter>[
      for (final c in cast['characters'] as List)
        if (c is Map)
          CastCharacter(
            name: c['name'].toString(),
            lines: (c['lines'] as num?)?.toInt() ?? 0,
            pagesSeen: 0,
            firstPage: null,
            gender: (c['gender'] ?? 'unknown').toString(),
            age: (c['age'] ?? 'unknown').toString(),
            temperament: (c['temperament'] ?? 'unknown').toString(),
            traitSource: 'cast',
            voice: (c['voice'] ?? 'narrator voice').toString(),
          ),
    ];
    if (list.isEmpty) return null;
    return CastData(characters: list, dialogueTotal: 0, dialogueAttributed: 0);
  }

  /// Reads the roster written on the phone (style.rate, assigned_voices) or by
  /// the server (voice_style.pitch_semitones), tolerating missing fields.
  factory CastData.fromJson(Map<String, dynamic> json) {
    final voices = (json['assigned_voices'] as Map?) ?? const {};
    String voiceFor(Map c) {
      final name = c['name'].toString();
      final style = c['style'];
      final vs = c['voice_style'];
      if (voices[name] != null && style is Map) {
        final speed = (style['rate'] as num?)?.toDouble() ?? 0.48;
        final x = speed / 0.48;
        return '${voices[name]}${(x - 1).abs() >= 0.03 ? ', speed ${x.toStringAsFixed(2)}x' : ''}';
      }
      if (vs is Map) {
        final p = (vs['pitch_semitones'] as num?)?.toInt() ?? 0;
        final gender = c['voice_gender']?.toString();
        final ref = gender == 'male' ? 'male voice' : gender == 'female' ? 'female voice' : 'narrator voice';
        return '$ref, pitch ${p >= 0 ? '+' : ''}$p';
      }
      return 'narrator voice';
    }

    final research = json['research'] is Map ? json['research'] as Map : null;
    final dialogue = (json['dialogue'] as Map?) ?? const {};
    final list = <CastCharacter>[
      for (final raw in (json['characters'] as List? ?? const []))
        if (raw is Map)
          () {
            final traits = (raw['traits'] as Map?) ?? const {};
            final pages = [for (final p in (raw['evidence_pages'] as List? ?? const [])) (p as num).toInt()];
            pages.sort();
            return CastCharacter(
              name: raw['name'].toString(),
              lines: (raw['lines'] as num?)?.toInt() ?? 0,
              pagesSeen: pages.length,
              firstPage: pages.isEmpty ? null : pages.first + 1,
              gender: (raw['voice_gender'] ?? traits['gender'] ?? 'unknown').toString(),
              age: (traits['age'] ?? 'unknown').toString(),
              temperament: (traits['temperament'] ?? 'unknown').toString(),
              traitSource: (traits['source'] ?? 'none').toString(),
              voice: voiceFor(raw),
            );
          }(),
    ]..sort((a, b) => b.lines != a.lines ? b.lines.compareTo(a.lines) : a.name.compareTo(b.name));
    return CastData(
      characters: list,
      dialogueTotal: (dialogue['total'] as num?)?.toInt() ?? 0,
      dialogueAttributed: (dialogue['attributed'] as num?)?.toInt() ?? 0,
      researchStatus: research?['status']?.toString(),
      researchReason: research?['reason']?.toString(),
      articles: [for (final a in (research?['articles'] as List? ?? (research?['article'] != null ? [research!['article']] : const []))) a.toString()],
      described: (research?['described'] as num?)?.toInt() ?? ((research?['characters'] as Map?)?.length ?? 0),
      notDescribed: [for (final n in (research?['not_described'] as List? ?? const [])) n.toString()],
      unmatchedOverrides: [for (final n in (json['unmatched_overrides'] as List? ?? const [])) n.toString()],
      scannedPages: (json['scanned_pages'] as num?)?.toInt(),
    );
  }
}

/// The cast of a downloaded novel, or null for books converted without one
/// (illustrated books, or books converted before this was recorded).
final castProvider = FutureProvider.autoDispose.family<CastData?, String>((ref, bookId) async {
  try {
    final repo = ref.read(libraryRepositoryProvider);
    final file = File(await repo.bookAssetPath(bookId, 'character_roster.json'));
    if (await file.exists()) {
      return CastData.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    }
    // Packages without a roster file (server cast books) still carry the
    // manifest `cast` key: engine, narrator and one entry per character.
    final manifest = File(await repo.bookAssetPath(bookId, 'manifest.json'));
    if (!await manifest.exists()) return null;
    return CastData.fromManifestCast((jsonDecode(await manifest.readAsString()) as Map<String, dynamic>)['cast']);
  } catch (_) {
    return null;
  }
});
