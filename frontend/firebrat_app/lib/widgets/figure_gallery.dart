import 'dart:io';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

/// Horizontally-scrollable row of every figure/table for the current
/// section. All of them stay visible and tappable at all times — the one
/// currently referenced by the playing segment is emphasized (border/scale),
/// never isolated or hidden, per the reader's requirement to freely browse
/// other diagrams while listening.
class FigureGallery extends StatelessWidget {
  final List<GalleryItem> items;
  final String? activeId;

  const FigureGallery({super.key, required this.items, required this.activeId});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 190,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(width: 12),
        itemBuilder: (context, i) => _FigureCard(item: items[i], active: items[i].id == activeId),
      ),
    );
  }
}

class GalleryItem {
  final String id;
  final String imagePath;
  final String caption;
  const GalleryItem({required this.id, required this.imagePath, required this.caption});
}

class _FigureCard extends StatelessWidget {
  final GalleryItem item;
  final bool active;
  const _FigureCard({required this.item, required this.active});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _openZoom(context),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 150,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: active ? scheme.primary : scheme.outlineVariant, width: active ? 3 : 1),
          boxShadow: active
              ? [BoxShadow(color: scheme.primary.withValues(alpha: 0.3), blurRadius: 12)]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Expanded(
              child: Container(
                color: scheme.surfaceContainerHighest,
                child: File(item.imagePath).existsSync()
                    ? Image.file(File(item.imagePath), fit: BoxFit.cover, width: double.infinity)
                    : const Center(child: Icon(Icons.image_not_supported_outlined)),
              ),
            ),
            if (item.caption.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  item.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _openZoom(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(item.caption)),
        body: PhotoView(
          imageProvider: FileImage(File(item.imagePath)),
          minScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.covered * 4,
        ),
      ),
    ));
  }
}
