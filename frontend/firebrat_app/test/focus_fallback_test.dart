import 'package:firebrat_app/models/manifest.dart';
import 'package:firebrat_app/models/visual_item.dart';
import 'package:firebrat_app/state/reader_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// Figures relinked to a section by caption are not tied to a narrated segment, so Focus Mode
/// (which follows the narrated segment's ref) used to show text only. It now falls back to the
/// section's own linked picture.
Manifest _manifest({List<String> figures = const ['fig_0001'], List<String> tables = const []}) => Manifest.fromJson({
      'book_id': 'b',
      'title': 'T',
      'sections': [
        {
          'section_id': 'sec_0001',
          'order': 1,
          'title': '3.2 Latches',
          'audio_path': 'a.m4a',
          'segments_path': 's.json',
          'figure_refs': figures,
          'table_refs': tables,
        }
      ],
      'figures': [
        {'figure_id': 'fig_0001', 'caption': 'Cross-coupled inverter pair', 'image_path': 'assets/figures/fig_0001.png'},
        {'figure_id': 'fig_0002', 'caption': 'Second', 'image_path': 'assets/figures/fig_0002.png'},
      ],
      'tables': [
        {'table_id': 'tbl_0001', 'caption': 'Truth table', 'image_path': 'assets/tables/tbl_0001.png'},
      ],
    });

ReaderState _state(Manifest m, {Map<String, String> assets = const {}, String? visualId}) => ReaderState(
      manifest: m,
      sectionIndex: 0,
      activeSegment: null,
      loadingSection: false,
      assetPaths: assets,
      currentVisualId: visualId,
    );

void main() {
  test('no narrated visual yet: falls back to the first linked figure', () {
    final v = _state(_manifest(), assets: {'fig_0001': '/x/fig_0001.png'}).currentVisual;
    expect(v?.id, 'fig_0001');
    expect(v?.kind, VisualKind.figure);
    expect(v?.caption, 'Cross-coupled inverter pair');
  });

  test('falls back to a linked table when the section has no figure', () {
    final v = _state(_manifest(figures: const [], tables: const ['tbl_0001']), assets: {'tbl_0001': '/x/t.png'}).currentVisual;
    expect(v?.id, 'tbl_0001');
    expect(v?.kind, VisualKind.table);
  });

  test('a narrated visual still wins over the fallback', () {
    final m = _manifest(figures: const ['fig_0001', 'fig_0002']);
    final v = _state(m, assets: {'fig_0001': '/a.png', 'fig_0002': '/b.png'}, visualId: 'fig_0002').currentVisual;
    expect(v?.id, 'fig_0002');
  });

  test('skips linked figures whose file is not resolved; null when nothing is available', () {
    expect(_state(_manifest(figures: const ['fig_0001', 'fig_0002']), assets: {'fig_0002': '/b.png'}).currentVisual?.id, 'fig_0002');
    expect(_state(_manifest()).currentVisual, isNull);
  });
}
