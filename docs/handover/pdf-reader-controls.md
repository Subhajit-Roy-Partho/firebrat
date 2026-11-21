# PDF reader controls and manual source images — 2026-11-19

Implemented in the Flutter app; no publish, commit, or deployment performed.

- Source PDF bottom row now has icon-only jump, previous section, live play/pause,
  next section, and crop controls. Section skips use the existing ReaderController
  and retain play/pause state. Unavailable/loading controls are disabled.
- PDF title and page follow section changes, including autoplay. Page navigation
  remains independent, so users can browse other pages without seeking narration.
- To add a missing diagram: navigate/zoom the source PDF to the diagram, tap crop,
  drag a rectangle, and choose "Use selected image". This captures the rendered
  PDF viewport (2x logical resolution), not an external image. Single-page PDF
  layout keeps page provenance unambiguous.
- The crop is associated with the section active when selection started, even if
  playback advances during selection. It overrides automatic visual selection for
  that section until removed/replaced. All original extracted assets are retained.
- Shared ReaderState.currentVisual feeds Focus Mode and notification/lock-screen
  art; the reader gallery also displays and emphasizes the selected crop.
- Selections survive section reload/app restart in per-section JSON/PNG records
  under the local book's source_selections directory. Generated manifests remain
  untouched, including manifests of partial books. This is local synchronization
  across app surfaces, not cross-device/Firestore sync.
- The image-with-slash action in the PDF app bar restores automatic section images.
- Opening/jumping back to a section with a selection uses its selected source page.

Validation:
- Changed Dart files analyzed without issues (the Dart launcher subsequently
  reports an unrelated denied write to its telemetry log).
- Direct Dart smoke check passed: save, reopen, section isolation, replacement,
  obsolete-image cleanup, removal, and repeated removal.
- Added widget tests for transport/play-state/boundaries/loading, crop PNG/cancel,
  saved visual precedence, and persistence tests. Flutter test execution is blocked
  in this sandbox by denied loopback socket binding (127.0.0.1, port 0); no tests
  reached their bodies. Run these outside the sandbox:

  cd frontend/firebrat_app
  flutter test test/source_pdf_screen_test.dart test/focus_fallback_test.dart \
    test/source_visual_store_test.dart test/pdf_image_selection_test.dart

Device QA still needed: PDF zoom/paging, crop fidelity, restarting/reopening saved
selections, autoplay following pages, restoring automatic images, and Android
notification/lock-screen artwork. No APK built or installed in this session.
