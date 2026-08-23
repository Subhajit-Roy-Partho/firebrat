import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/visual_item.dart';
import '../state/reader_providers.dart';
import '../widgets/playback_bar_bound.dart';

/// Full-screen "now playing" view: just the current image or formula,
/// crossfading smoothly as playback moves from one to the next, with
/// transport controls pinned at the bottom. Reachable from the reader via
/// the app bar's fullscreen action; the system back gesture / close button
/// return to the normal reading view without interrupting playback.
class FocusModeScreen extends ConsumerWidget {
  final String bookId;
  const FocusModeScreen({super.key, required this.bookId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerControllerProvider(bookId));
    if (state == null) {
      return const Scaffold(backgroundColor: Colors.black, body: SizedBox.shrink());
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  tooltip: 'Exit focus mode',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Text(
                    state.section.title,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
                const SizedBox(width: 48), // balances the close button so the title stays centered
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 450),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween(begin: 0.96, end: 1.0).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _FocusContent(
                    key: ValueKey(state.currentVisual?.id ?? 'focus-empty'),
                    visual: state.currentVisual,
                    segmentText: state.activeSegment?.text,
                  ),
                ),
              ),
            ),
            PlaybackBarBound(bookId: bookId, themeOverride: ThemeData(brightness: Brightness.dark, useMaterial3: true)),
          ],
        ),
      ),
    );
  }
}

class _FocusContent extends StatelessWidget {
  final VisualItem? visual;
  final String? segmentText;
  const _FocusContent({super.key, required this.visual, required this.segmentText});

  @override
  Widget build(BuildContext context) {
    if (visual == null) {
      // Nothing visual yet for this stretch of narration — keep the
      // listener oriented with the text currently being spoken.
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            segmentText?.isNotEmpty == true ? segmentText! : 'Listening…',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 22, height: 1.4),
          ),
        ),
      );
    }

    final v = visual!;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
          child: v.kind == VisualKind.formula
              ? _BigFormula(latex: v.latex ?? '', imagePath: v.imagePath)
              : _BigImage(imagePath: v.imagePath),
        ),
        if (v.caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              v.caption,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ),
      ],
    );
  }
}

class _BigImage extends StatelessWidget {
  final String imagePath;
  const _BigImage({required this.imagePath});

  @override
  Widget build(BuildContext context) {
    final file = File(imagePath);
    if (!file.existsSync()) {
      return const Center(child: Icon(Icons.image_not_supported_outlined, color: Colors.white38, size: 64));
    }
    return Center(child: Image.file(file, fit: BoxFit.contain));
  }
}

class _BigFormula extends StatelessWidget {
  final String latex;
  final String imagePath;
  const _BigFormula({required this.latex, required this.imagePath});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: _buildMath(context),
        ),
      ),
    );
  }

  Widget _buildMath(BuildContext context) {
    try {
      return Math.tex(
        latex,
        textStyle: const TextStyle(fontSize: 40, color: Colors.white),
        onErrorFallback: (err) => _imageFallback(),
      );
    } catch (_) {
      return _imageFallback();
    }
  }

  Widget _imageFallback() {
    final file = File(imagePath);
    if (!file.existsSync()) {
      return Text(latex, style: const TextStyle(color: Colors.white, fontSize: 22));
    }
    return Image.file(file, fit: BoxFit.contain);
  }
}
