import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/library_providers.dart';
import '../utils/community_helpers.dart';

/// Browses the shared Community library (Firestore `books` where
/// status == 'published'). Packages live on the Internet Archive; adding
/// one downloads it and runs it through the normal local import path.
class CommunityScreen extends ConsumerStatefulWidget {
  const CommunityScreen({super.key});

  @override
  ConsumerState<CommunityScreen> createState() => _CommunityScreenState();
}

const _categories = [
  'all',
  'fiction',
  'nonfiction',
  'science',
  'history',
  'poetry',
  'children',
  'education',
  'other',
];

const _communityBase = 'https://subhajit-roy-partho.github.io/firebrat/community';

class _CommunityScreenState extends ConsumerState<CommunityScreen> {
  String _search = '';
  String _category = 'all';
  int _limit = 30;
  bool _firebaseMissing = false;

  Stream<QuerySnapshot<Map<String, dynamic>>>? _queryStream() {
    try {
      final query = FirebaseFirestore.instance
          .collection('books')
          .where('status', isEqualTo: 'published')
          .orderBy('createdAt', descending: true)
          .limit(_limit);
      return query.snapshots();
    } catch (_) {
      // Fail-open when Firebase isn't initialized (e.g. non-Android dev
      // builds without google-services config): show a friendly note.
      _firebaseMissing = true;
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final stream = _queryStream();
    return Scaffold(
      appBar: AppBar(title: const Text('Community library')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search title or author',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                for (final c in _categories)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(c[0].toUpperCase() + c.substring(1)),
                      selected: _category == c,
                      onSelected: (_) => setState(() => _category = c),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: stream == null || _firebaseMissing
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Community library needs Firebase, which isn\'t set up on this device. Your on-device books still work fully offline.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: stream,
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'Couldn\'t load the community library.\n${snap.error}',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                      }
                      if (!snap.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      var docs = snap.data!.docs;
                      if (_category != 'all') {
                        docs = docs
                            .where((d) => (d.data()['category'] as String? ?? 'other') == _category)
                            .toList();
                      }
                      if (_search.isNotEmpty) {
                        docs = docs.where((d) {
                          final data = d.data();
                          final hay =
                              '${data['title'] ?? ''} ${data['author'] ?? ''}'.toLowerCase();
                          return hay.contains(_search);
                        }).toList();
                      }
                      if (docs.isEmpty) {
                        return const Center(
                          child: Text('No community books match — try another search.'),
                        );
                      }
                      return ListView.builder(
                        itemCount: docs.length + 1,
                        itemBuilder: (context, i) {
                          if (i == docs.length) {
                            // Reached the page limit: offer more.
                            if (snap.data!.docs.length < _limit) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.all(16),
                              child: OutlinedButton(
                                onPressed: () => setState(() => _limit += 30),
                                child: const Text('Load more'),
                              ),
                            );
                          }
                          final doc = docs[i];
                          final data = doc.data();
                          return _CommunityTile(
                            bookId: doc.id,
                            data: data,
                            onTap: () => _showDetail(context, ref, doc.id, data),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _showDetail(
    BuildContext context,
    WidgetRef ref,
    String bookId,
    Map<String, dynamic> data,
  ) async {
    final title = data['title'] as String? ?? bookId;
    final provenance = (data['provenance'] as Map<String, dynamic>?) ?? {};
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _CoverBadge(title: title, size: 56),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: Theme.of(sheetContext).textTheme.titleLarge),
                        Text(
                          (data['author'] as String? ?? '').isEmpty
                              ? 'Unknown author'
                              : data['author'] as String,
                          style: Theme.of(sheetContext).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  Chip(label: Text((data['license'] as String?) ?? (provenance['license'] as String?) ?? 'unknown')),
                  Chip(
                    avatar: const Icon(Icons.star_rounded, size: 16),
                    label: Text(
                      '${ratingAverage((data['ratingSum'] ?? 0) as num, (data['ratingCount'] ?? 0) as num).toStringAsFixed(1)} (${(data['ratingCount'] ?? 0)})',
                    ),
                  ),
                  Chip(label: Text(formatDuration((data['totalDurationMs'] ?? 0) as int))),
                ],
              ),
              if ((data['description'] as String?)?.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                Text(data['description'] as String),
              ],
              const SizedBox(height: 16),
              Text('How this audio was made',
                  style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 6),
              ..._provenanceRows(provenance, data),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  _addToLibrary(context, ref, bookId, data);
                },
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add to my library'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => launchUrl(
                        Uri.parse('$_communityBase/#/book/$bookId'),
                        mode: LaunchMode.externalApplication,
                      ),
                      icon: const Icon(Icons.public_rounded),
                      label: const Text('Open on website'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: () => launchUrl(
                        Uri.parse('$_communityBase/#/legal/takedown?book=$bookId'),
                        mode: LaunchMode.externalApplication,
                      ),
                      icon: const Icon(Icons.flag_outlined),
                      label: const Text('Report concern'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _provenanceRows(Map<String, dynamic> provenance, Map<String, dynamic> data) {
    final rows = <Widget>[];
    void row(String label, String? value) {
      if (value == null || value.isEmpty) return;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(color: Colors.grey, fontSize: 14),
            children: [
              TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: value),
            ],
          ),
        ),
      ));
    }

    row('Generation', provenance['generation'] as String?);
    row('Narration engine', provenance['narrationEngine'] as String?);
    final models = provenance['models'];
    if (models is List && models.isNotEmpty) row('Models', models.join(', '));
    row('Pipeline notes', provenance['pipelineNotes'] as String?);
    row('Source', (provenance['sourceTitle'] as String?) ?? (data['sourceTitle'] as String?));
    row('Source URL', (provenance['sourceUrl'] as String?)?.toString());
    row('License', (provenance['license'] as String?) ?? (data['license'] as String?)?.toString());
    row('License URL', (provenance['licenseUrl'] as String?)?.toString());
    if (rows.isEmpty) {
      rows.add(const Text('No provenance details were provided for this book.',
          style: TextStyle(color: Colors.grey)));
    }
    return rows;
  }

  Future<void> _addToLibrary(
    BuildContext context,
    WidgetRef ref,
    String bookId,
    Map<String, dynamic> data,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final archiveUrl = data['archiveUrl'] as String? ?? '';
    if (!isAllowedArchiveUrl(archiveUrl)) {
      messenger.showSnackBar(const SnackBar(
          content: Text('This book links outside the Internet Archive — refused for safety.')));
      return;
    }
    late final String archiveId;
    try {
      archiveId = archiveIdFromUrl(archiveUrl);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Bad archive link: $e')));
      return;
    }
    final packageKind = data['packageKind'] as String? ?? 'zip';
    final cancelToken = CancelToken();
    final progress = ValueNotifier<double?>(null);
    // Progress dialog with cancel.
    var dialogOpen = false;
    if (context.mounted) {
      dialogOpen = true;
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text('Downloading "$bookId"'),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, v, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: v),
                const SizedBox(height: 8),
                Text(v == null ? 'Starting…' : '${(v * 100).round()}%'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelToken.cancel('cancelled by user');
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ).then((_) => dialogOpen = false));
    }

    File? tempFile;
    try {
      final dio = Dio();
      late final String downloadUrl;
      if (packageKind == 'folder') {
        downloadUrl = 'https://archive.org/compress/$archiveId';
      } else {
        // Zip route: look up the first .zip in the item metadata.
        final meta = await dio.get<Map<String, dynamic>>(
          'https://archive.org/metadata/$archiveId',
          cancelToken: cancelToken,
        );
        final files = (meta.data?['files'] as List?) ?? const [];
        String? zipName;
        for (final f in files) {
          final name = (f as Map)['name'] as String? ?? '';
          if (name.toLowerCase().endsWith('.zip')) {
            zipName = name;
            break;
          }
        }
        if (zipName == null) {
          throw StateError('No .zip package found for "$archiveId"');
        }
        downloadUrl = 'https://archive.org/download/$archiveId/$zipName';
      }
      if (!isAllowedArchiveUrl(downloadUrl)) {
        throw StateError('Resolved download URL is not on the Internet Archive');
      }
      final tmpDir = Directory.systemTemp;
      tempFile = File('${tmpDir.path}/firebrat-community-$archiveId.zip');
      await dio.download(
        downloadUrl,
        tempFile.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          progress.value = total > 0 ? received / total : null;
        },
      );
      final importedId =
          await ref.read(importManagerProvider).importFromFile(tempFile);
      invalidateLibrary(ref);
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // close progress
        dialogOpen = false;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Added "$importedId" to your library')));
      }
    } on DioException catch (e) {
      if (context.mounted) {
        if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
        dialogOpen = false;
        if (e.type != DioExceptionType.cancel) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Download failed: $e')));
        }
      }
    } catch (e) {
      if (context.mounted) {
        if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
        dialogOpen = false;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not add book: $e')));
      }
    } finally {
      try {
        if (tempFile != null && await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
    }
  }
}

class _CommunityTile extends StatelessWidget {
  final String bookId;
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  const _CommunityTile({required this.bookId, required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final title = data['title'] as String? ?? bookId;
    final author = (data['author'] as String?)?.isNotEmpty == true
        ? data['author'] as String
        : 'Unknown author';
    final license =
        (data['license'] as String?) ?? ((data['provenance'] as Map?)?['license'] as String?);
    return ListTile(
      onTap: onTap,
      leading: _CoverBadge(title: title, size: 48),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$author · ${formatDuration((data['totalDurationMs'] ?? 0) as int)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.star_rounded, size: 16),
              const SizedBox(width: 2),
              Text(ratingAverage(
                (data['ratingSum'] ?? 0) as num,
                (data['ratingCount'] ?? 0) as num,
              ).toStringAsFixed(1)),
              Text(' (${(data['ratingCount'] ?? 0)})',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          if (license != null)
            Chip(
              label: Text(license, style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }
}

/// Deterministic gradient cover with the title's first letter.
class _CoverBadge extends StatelessWidget {
  final String title;
  final double size;
  const _CoverBadge({required this.title, required this.size});

  @override
  Widget build(BuildContext context) {
    final colors = coverColors(title);
    final letter = title.trim().isEmpty ? '?' : title.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.45,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
