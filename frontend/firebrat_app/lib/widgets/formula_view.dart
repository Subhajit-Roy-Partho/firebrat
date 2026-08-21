import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// Renders a formula's LaTeX as crisp vector math (flutter_math_fork), with
/// the pre-rendered PNG from the manifest as a fallback if the LaTeX fails
/// to parse (marker's extracted/LLM-authored LaTeX can occasionally use
/// something the KaTeX-subset parser doesn't support). Glows when [active].
class FormulaView extends StatelessWidget {
  final String latex;
  final String imagePath; // absolute local file path
  final bool active;

  const FormulaView({super.key, required this.latex, required this.imagePath, this.active = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: active ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: active ? scheme.primary : Colors.transparent,
          width: 2,
        ),
        boxShadow: active
            ? [BoxShadow(color: scheme.primary.withValues(alpha: 0.25), blurRadius: 16, spreadRadius: 1)]
            : null,
      ),
      child: Center(
        child: _buildMath(context),
      ),
    );
  }

  Widget _buildMath(BuildContext context) {
    try {
      return Math.tex(
        latex,
        textStyle: const TextStyle(fontSize: 20),
        onErrorFallback: (err) => _imageFallback(context),
      );
    } catch (_) {
      return _imageFallback(context);
    }
  }

  Widget _imageFallback(BuildContext context) {
    final file = File(imagePath);
    if (!file.existsSync()) {
      return Text(latex, style: Theme.of(context).textTheme.bodyLarge);
    }
    return Image.file(file, fit: BoxFit.contain);
  }
}
