import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Hero tag shared by the library cover and the reader, so the cover
/// flies into place when a book opens.
String bookCoverHeroTag(String bookId) => 'book-cover-$bookId';

/// A 2:3 book cover. Uses the cover image shipped in the book package when
/// there is one; otherwise paints a unique, deterministic cover from the
/// title and id (palette + motif), so every book on the shelf looks
/// distinct. Title and author are painted (not Text widgets) so the cover
/// never duplicates the card's own labels in the semantics tree.
class BookCover extends StatelessWidget {
  final String bookId;
  final String title;
  final String author;
  final String? coverPath;
  final double radius;

  const BookCover({
    super.key,
    required this.bookId,
    required this.title,
    this.author = '',
    this.coverPath,
    this.radius = 10,
  });

  static const aspect = 2 / 3;

  @override
  Widget build(BuildContext context) {
    final generated = Semantics(
      label: 'Default book cover',
      image: true,
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, c) => CustomPaint(
            size: Size(c.maxWidth, c.maxHeight),
            painter: _CoverPainter(bookId: bookId, title: title, author: author),
          ),
        ),
      ),
    );
    final Widget face = coverPath == null
        ? generated
        : Image.file(
            File(coverPath!),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => generated,
          );
    return Hero(
      tag: bookCoverHeroTag(bookId),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              face,
              // Spine crease + soft top-left sheen: reads as a real book.
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      stops: const [0, .035, .07, .12, 1],
                      colors: [
                        Colors.black.withValues(alpha: .35),
                        Colors.white.withValues(alpha: .16),
                        Colors.black.withValues(alpha: .10),
                        Colors.transparent,
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(alpha: .14),
                        Colors.transparent,
                        Colors.transparent,
                      ],
                      stops: const [0, .4, 1],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Palette {
  final Color a, b, accent;
  const _Palette(this.a, this.b, this.accent);
}

// Jewel tones with one warm accent each; all keep white text above 4.5:1.
const _palettes = <_Palette>[
  _Palette(Color(0xFF1E1B4B), Color(0xFF4338CA), Color(0xFFFBBF24)), // indigo / amber
  _Palette(Color(0xFF3B0764), Color(0xFF9333EA), Color(0xFFFB923C)), // violet / orange
  _Palette(Color(0xFF042F2E), Color(0xFF0F766E), Color(0xFFFDE68A)), // teal / sand
  _Palette(Color(0xFF450A0A), Color(0xFFB91C1C), Color(0xFFFCD34D)), // crimson / gold
  _Palette(Color(0xFF0C2D48), Color(0xFF1D6FA5), Color(0xFFFCA5A5)), // ocean / coral
  _Palette(Color(0xFF1A2E05), Color(0xFF4D7C0F), Color(0xFFFEF08A)), // forest / lime
  _Palette(Color(0xFF4A044E), Color(0xFFC026D3), Color(0xFF67E8F9)), // orchid / cyan
  _Palette(Color(0xFF1F2937), Color(0xFF475569), Color(0xFFF472B6)), // slate / pink
];

int _hash(String s) {
  var h = 0x811C9DC5;
  for (final u in s.codeUnits) {
    h = ((h ^ u) * 0x01000193) & 0x7FFFFFFF;
  }
  return h;
}

class _CoverPainter extends CustomPainter {
  final String bookId;
  final String title;
  final String author;
  _CoverPainter({required this.bookId, required this.title, required this.author});

  @override
  void paint(Canvas canvas, Size size) {
    final h = _hash('$bookId|$title');
    final p = _palettes[h % _palettes.length];
    final motif = (h >> 5) % 4;
    final w = size.width, ht = size.height;
    final rect = Offset.zero & size;

    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p.b, p.a],
        ).createShader(rect),
    );

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, w * .012)
      ..strokeCap = StrokeCap.round;
    switch (motif) {
      case 0: // sound ribbons rising from the lower right
        for (var i = 0; i < 9; i++) {
          line.color = p.accent.withValues(alpha: .08 + i * .035);
          final r = w * (.35 + i * .13);
          canvas.drawArc(
            Rect.fromCircle(center: Offset(w * .95, ht * .98), radius: r),
            math.pi * 1.0,
            math.pi * .5,
            false,
            line,
          );
        }
      case 1: // waveform bars along the bottom
        final bars = 15;
        final gap = w / (bars + 1);
        for (var i = 0; i < bars; i++) {
          final amp = (math.sin(i * .9 + (h % 7)) * .5 + .5) * .16 + .03;
          line
            ..strokeWidth = gap * .45
            ..color = p.accent.withValues(alpha: .20 + amp);
          final x = gap * (i + 1);
          canvas.drawLine(
            Offset(x, ht * .93 - ht * amp),
            Offset(x, ht * .93),
            line,
          );
        }
      case 2: // horizon sun and hills
        canvas.drawCircle(
          Offset(w * .68, ht * .64),
          w * .16,
          Paint()..color = p.accent.withValues(alpha: .85),
        );
        for (var i = 0; i < 3; i++) {
          final path = Path()
            ..moveTo(0, ht)
            ..lineTo(0, ht * (.70 + i * .08))
            ..quadraticBezierTo(
                w * (.25 + i * .15), ht * (.58 + i * .07), w * (.55 + i * .1), ht * (.72 + i * .06))
            ..quadraticBezierTo(w * .85, ht * (.82 + i * .04), w, ht * (.68 + i * .08))
            ..lineTo(w, ht)
            ..close();
          canvas.drawPath(
            path,
            Paint()..color = p.a.withValues(alpha: .35 + i * .22),
          );
        }
      default: // constellation of dots
        final rnd = math.Random(h);
        final dot = Paint()..color = p.accent;
        final pts = [
          for (var i = 0; i < 9; i++)
            Offset(w * (.12 + rnd.nextDouble() * .76), ht * (.52 + rnd.nextDouble() * .40)),
        ];
        line
          ..strokeWidth = math.max(1, w * .008)
          ..color = p.accent.withValues(alpha: .35);
        for (var i = 0; i < pts.length - 1; i++) {
          canvas.drawLine(pts[i], pts[i + 1], line);
        }
        for (final o in pts) {
          canvas.drawCircle(o, w * .016 + rnd.nextDouble() * w * .012, dot);
        }
    }

    // Accent rule + title + author.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * .12, ht * .09, w * .16, math.max(2, w * .018)),
        const Radius.circular(2),
      ),
      Paint()..color = p.accent,
    );
    // Size from the title length, then shrink so the longest word never
    // breaks mid-word.
    var scale = title.length > 40 ? .095 : title.length > 22 ? .115 : .135;
    final longest = title
        .split(RegExp(r'\s+'))
        .fold<int>(1, (m, wd) => math.max(m, wd.length));
    scale = math.min(scale, .74 / (longest * .58));
    final titleStyle = TextStyle(
      color: Colors.white,
      fontFamily: 'serif',
      fontWeight: FontWeight.w700,
      fontSize: w * scale,
      height: 1.12,
      shadows: const [Shadow(color: Color(0x66000000), blurRadius: 6)],
    );
    final tp = TextPainter(
      text: TextSpan(text: title, style: titleStyle),
      textDirection: TextDirection.ltr,
      maxLines: 5,
      ellipsis: '…',
    )..layout(maxWidth: w * .76);
    tp.paint(canvas, Offset(w * .12, ht * .14));
    if (author.isNotEmpty) {
      final ap = TextPainter(
        text: TextSpan(
          text: author.toUpperCase(),
          style: TextStyle(
            color: Colors.white.withValues(alpha: .88),
            fontFamily: 'Roboto',
            fontSize: w * .062,
            letterSpacing: w * .008,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 3,
        ellipsis: '…',
      )..layout(maxWidth: w * .54);
      ap.paint(canvas, Offset(w * .12, ht - ap.height - ht * .055));
    }
  }

  @override
  bool shouldRepaint(_CoverPainter old) =>
      old.bookId != bookId || old.title != title || old.author != author;
}

/// The generated cover as PNG bytes — used for the lock-screen / notification
/// artwork when a book ships no cover image of its own. Same painter as the
/// library, so the artwork matches what the user sees on their shelf.
Future<Uint8List> renderGeneratedCoverPng({
  required String bookId,
  required String title,
  String author = '',
  int width = 600,
}) async {
  final size = ui.Size(width.toDouble(), width * 1.5);
  final recorder = ui.PictureRecorder();
  _CoverPainter(bookId: bookId, title: title, author: author)
      .paint(ui.Canvas(recorder), size);
  final image = await recorder
      .endRecording()
      .toImage(size.width.toInt(), size.height.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}
