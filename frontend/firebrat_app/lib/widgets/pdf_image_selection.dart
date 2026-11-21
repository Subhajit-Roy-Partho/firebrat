import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Selects a rectangle on a frozen PDF viewport, so scrolling/zooming the
/// live viewer cannot move the source underneath the selection gesture.
class PdfImageSelection extends StatefulWidget {
  final ui.Image image;
  const PdfImageSelection({super.key, required this.image});

  @override
  State<PdfImageSelection> createState() => _PdfImageSelectionState();
}

class _PdfImageSelectionState extends State<PdfImageSelection> {
  // Navigator.push completes before its reverse transition finishes. Keep
  // our own image handle alive until this route has actually been removed.
  late final ui.Image _image = widget.image.clone();
  Offset? _start;
  Rect? _selection;
  Rect _imageRect = Rect.zero;
  bool _saving = false;

  @override
  void dispose() {
    _image.dispose();
    super.dispose();
  }

  Offset _clamp(Offset p) => Offset(
    p.dx.clamp(_imageRect.left, _imageRect.right),
    p.dy.clamp(_imageRect.top, _imageRect.bottom),
  );

  Future<void> _save() async {
    final selection = _selection;
    if (selection == null || _saving) return;
    setState(() => _saving = true);
    ui.Image? crop;
    try {
      final scale = _image.width / _imageRect.width;
      final source = Rect.fromLTWH(
        (selection.left - _imageRect.left) * scale,
        (selection.top - _imageRect.top) * scale,
        selection.width * scale,
        selection.height * scale,
      );
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        _image,
        source,
        Rect.fromLTWH(0, 0, source.width, source.height),
        Paint(),
      );
      final picture = recorder.endRecording();
      try {
        crop = await picture.toImage(source.width.ceil(), source.height.ceil());
      } finally {
        picture.dispose();
      }
      final bytes = await crop.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('Could not capture the image.');
      if (mounted) {
        Navigator.of(context).pop<Uint8List>(bytes.buffer.asUint8List());
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not select this image. Try again.'),
          ),
        );
      }
    } finally {
      crop?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Select image from PDF')),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Drag around the image. It will be used for this section in the reader, Focus Mode and playback artwork.',
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(
                _image.width.toDouble(),
                _image.height.toDouble(),
              );
              final fitted = applyBoxFit(
                BoxFit.contain,
                size,
                constraints.biggest,
              );
              _imageRect = Alignment.center.inscribe(
                fitted.destination,
                Offset.zero & constraints.biggest,
              );
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: _saving
                    ? null
                    : (details) => setState(() {
                        _start = _clamp(details.localPosition);
                        _selection = null;
                      }),
                onPanUpdate: _saving
                    ? null
                    : (details) => setState(() {
                        if (_start != null) {
                          _selection = Rect.fromPoints(
                            _start!,
                            _clamp(details.localPosition),
                          );
                        }
                      }),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RawImage(image: _image, fit: BoxFit.contain),
                    if (_selection != null)
                      Positioned.fromRect(
                        rect: _selection!,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: .15),
                              border: Border.all(color: Colors.blue, width: 2),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed:
                  !_saving &&
                      (_selection?.width ?? 0) >= 12 &&
                      (_selection?.height ?? 0) >= 12
                  ? _save
                  : null,
              icon: const Icon(Icons.check),
              label: Text(_saving ? 'Saving…' : 'Use selected image'),
            ),
          ),
        ),
      ],
    ),
  );
}
