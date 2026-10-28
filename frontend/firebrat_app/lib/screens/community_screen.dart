import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_network_gate.dart';
import '../services/community_service.dart';
import '../state/library_providers.dart';
import '../utils/community_helpers.dart';
import '../utils/work_grouping.dart';
import '../widgets/community_detail_sheet.dart';

/// Browses the shared Community library (Firestore `books` where
/// status == 'published'). Several uploads of the same book are grouped under
/// one banner (best-rated first); packages live on the Internet Archive and
/// adding one downloads it and runs it through the normal local import path.
/// Rating, reviewing and bookmarking need a sign-in (see CommunityDetailSheet).
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

class _CommunityScreenState extends ConsumerState<CommunityScreen> {
  String _search = '';
  String _category = 'all';
  CommunitySort _sort = CommunitySort.top;
  bool _savedOnly = false;
  String? _author; // null = all authors
  String? _uploader; // null = all uploaders
  int _limit = 100;
  bool _firebaseMissing = false;

  Stream<QuerySnapshot<Map<String, dynamic>>>? _queryStream() {
    try {
      // Newest-first is the only order Firestore can index here; grouping and every
      // other sort happen on the device so duplicate uploads can sit together.
      return FirebaseFirestore.instance
          .collection('books')
          .where('status', isEqualTo: 'published')
          .orderBy('createdAt', descending: true)
          .limit(_limit)
          .snapshots();
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
              onChanged: (v) =>
                  setState(() => _search = v.trim().toLowerCase()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.sort_rounded, size: 20),
                const SizedBox(width: 8),
                DropdownButton<CommunitySort>(
                  value: _sort,
                  underline: const SizedBox.shrink(),
                  onChanged: (v) =>
                      setState(() => _sort = v ?? CommunitySort.top),
                  items: [
                    for (final s in CommunitySort.values)
                      DropdownMenuItem(value: s, child: Text(s.label)),
                  ],
                ),
                const Spacer(),
                FilterChip(
                  avatar: Icon(
                    _savedOnly
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_border_rounded,
                    size: 18,
                  ),
                  label: const Text('Saved'),
                  selected: _savedOnly,
                  onSelected: (v) => setState(() => _savedOnly = v),
                ),
              ],
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
                : StreamBuilder<User?>(
                    stream: CommunityService.instance.authChanges(),
                    initialData: CommunityService.instance.user,
                    builder: (context, authSnap) => StreamBuilder<Set<String>>(
                      stream: CommunityService.instance.favorites(),
                      builder: (context, favSnap) => _buildList(
                        stream,
                        authSnap.data,
                        favSnap.data ?? const <String>{},
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
    Stream<QuerySnapshot<Map<String, dynamic>>> stream,
    User? user,
    Set<String> saved,
  ) {
    if (_savedOnly && user == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Sign in (open any book and tap "Sign in with Google") to bookmark books and see them here.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
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
        final fetched = snap.data!.docs.length;
        var items = [
          for (final d in snap.data!.docs) {...d.data(), 'id': d.id},
        ];
        // Filter options come from what has been loaded, before any filter narrows it.
        final authors = _distinct(items, 'author');
        final uploaders = _distinct(items, 'submitterName');
        if (_author != null && authors.contains(_author)) {
          items = items.where((b) => b['author'] == _author).toList();
        }
        if (_uploader != null && uploaders.contains(_uploader)) {
          items = items.where((b) => b['submitterName'] == _uploader).toList();
        }
        if (_category != 'all') {
          items = items
              .where((b) => (b['category'] as String? ?? 'other') == _category)
              .toList();
        }
        if (_savedOnly) {
          items = items.where((b) => saved.contains(b['id'])).toList();
        }
        if (_search.isNotEmpty) {
          items = items
              .where(
                (b) => '${b['title'] ?? ''} ${b['author'] ?? ''}'
                    .toLowerCase()
                    .contains(_search),
              )
              .toList();
        }
        final works = groupWorks(items, _sort);
        if (works.isEmpty) {
          return Center(
            child: Text(
              _savedOnly
                  ? 'No bookmarked books yet.'
                  : 'No community books match — try another search.',
            ),
          );
        }
        final list = ListView.builder(
          itemCount: works.length + 1,
          itemBuilder: (context, i) {
            if (i == works.length) {
              if (fetched < _limit) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton(
                  onPressed: () => setState(() => _limit += 100),
                  child: const Text('Load more'),
                ),
              );
            }
            final w = works[i];
            if (w.editions.length == 1) {
              final b = w.best;
              return _CommunityTile(
                data: b,
                saved: saved.contains(b['id']),
                onTap: () => _showDetail(context, b['id'] as String, b),
              );
            }
            return _WorkBanner(
              work: w,
              saved: saved,
              onOpen: (b) => _showDetail(context, b['id'] as String, b),
            );
          },
        );
        return Column(
          children: [
            _filterRow(authors, uploaders),
            Expanded(child: list),
          ],
        );
      },
    );
  }

  /// Sorted distinct non-empty values of [key] across [items].
  List<String> _distinct(List<Map<String, dynamic>> items, String key) {
    final out = <String>{
      for (final b in items)
        if ((b[key] as String?)?.trim().isNotEmpty == true)
          (b[key] as String).trim(),
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return out;
  }

  Widget _filterRow(List<String> authors, List<String> uploaders) {
    Widget picker(
      String hint,
      IconData icon,
      String? value,
      List<String> options,
      ValueChanged<String?> onChanged,
    ) {
      return Expanded(
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String?>(
            isExpanded: true,
            value: options.contains(value) ? value : null,
            icon: Icon(icon, size: 18),
            hint: Text(hint),
            onChanged: onChanged,
            items: [
              DropdownMenuItem<String?>(value: null, child: Text(hint)),
              for (final o in options)
                DropdownMenuItem<String?>(
                  value: o,
                  child: Text(o, overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          picker(
            'All authors',
            Icons.person_outline_rounded,
            _author,
            authors,
            (v) => setState(() => _author = v),
          ),
          const SizedBox(width: 12),
          picker(
            'All uploaders',
            Icons.upload_outlined,
            _uploader,
            uploaders,
            (v) => setState(() => _uploader = v),
          ),
        ],
      ),
    );
  }

  Future<void> _showDetail(
    BuildContext context,
    String bookId,
    Map<String, dynamic> data,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => CommunityDetailSheet(
        bookId: bookId,
        data: data,
        onAdd: () => _addToLibrary(context, ref, bookId, data),
      ),
    );
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
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'This book links outside the Internet Archive — refused for safety.',
          ),
        ),
      );
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
    // Non-null while the "Download over" setting holds this download.
    final waiting = ValueNotifier<String?>(null);
    // Progress dialog with cancel.
    var dialogOpen = false;
    if (context.mounted) {
      dialogOpen = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: Text('Downloading "$bookId"'),
            content: ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (_, v, _) => ValueListenableBuilder<String?>(
                valueListenable: waiting,
                builder: (_, wait, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(value: wait != null ? 0 : v),
                    const SizedBox(height: 8),
                    Text(
                      wait ??
                          (v == null ? 'Starting…' : '${(v * 100).round()}%'),
                    ),
                    if (wait != null)
                      const Text(
                        'It starts automatically when Wi-Fi is available '
                        '(Settings > Download over).',
                      ),
                  ],
                ),
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
        ).then((_) => dialogOpen = false),
      );
    }

    File? tempFile;
    try {
      final dio = Dio();
      late final String downloadUrl;
      int? sizeBytes;
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
            sizeBytes = int.tryParse('${f['size'] ?? ''}');
            break;
          }
        }
        if (zipName == null) {
          throw StateError('No .zip package found for "$archiveId"');
        }
        downloadUrl = 'https://archive.org/download/$archiveId/$zipName';
      }
      if (!isAllowedArchiveUrl(downloadUrl)) {
        throw StateError(
          'Resolved download URL is not on the Internet Archive',
        );
      }
      final tmpDir = Directory.systemTemp;
      tempFile = File('${tmpDir.path}/firebrat-community-$archiveId.zip');
      // "Download over" rule (this download cannot resume mid-file, so it waits
      // before starting). Size unknown (folder route): assume a large file.
      final allowed = await AppNetworkGate.instance.waitUntilAllowed(
        sizeBytes ?? 100 * 1024 * 1024,
        onWaiting: (label) => waiting.value = label,
        isCancelled: () => cancelToken.isCancelled,
      );
      if (!allowed) return;
      await dio.download(
        downloadUrl,
        tempFile.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          progress.value = total > 0 ? received / total : null;
        },
      );
      final importedId = await ref
          .read(importManagerProvider)
          .importFromFile(tempFile);
      invalidateLibrary(ref);
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // close progress
        dialogOpen = false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added "$importedId" to your library')),
        );
      }
    } on DioException catch (e) {
      if (context.mounted) {
        if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
        dialogOpen = false;
        if (e.type != DioExceptionType.cancel) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
        }
      }
    } catch (e) {
      if (context.mounted) {
        if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
        dialogOpen = false;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not add book: $e')));
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

String _licenseOf(Map<String, dynamic> data) =>
    (data['license'] as String?) ??
    ((data['provenance'] as Map?)?['license'] as String?) ??
    '';

class _RatingText extends StatelessWidget {
  const _RatingText(this.data);
  final Map<String, dynamic> data;
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.star_rounded, size: 16),
        const SizedBox(width: 2),
        Text(avgRating(data).toStringAsFixed(1)),
        Text(
          ' (${(data['ratingCount'] ?? 0)})',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _CommunityTile extends StatelessWidget {
  const _CommunityTile({
    required this.data,
    required this.saved,
    required this.onTap,
  });
  final Map<String, dynamic> data;
  final bool saved;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = data['title'] as String? ?? data['id'] as String? ?? '';
    final author = (data['author'] as String?)?.isNotEmpty == true
        ? data['author'] as String
        : 'Unknown author';
    final license = _licenseOf(data);
    return ListTile(
      onTap: onTap,
      leading: CommunityCover(
        title: title,
        size: 48,
        imageUrl: communityCoverUrl(data),
        pngUrl: communityCoverUrl(data, ext: 'png'),
      ),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$author · ${formatDuration(((data['totalDurationMs'] ?? 0) as num).toInt())}\n${submitterLabel(data)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (saved) const Icon(Icons.bookmark_rounded, size: 16),
              _RatingText(data),
            ],
          ),
          if (license.isNotEmpty)
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

/// One book uploaded several times: a single banner listing every version, best-rated
/// first, with who submitted it and its stars.
class _WorkBanner extends StatelessWidget {
  const _WorkBanner({
    required this.work,
    required this.saved,
    required this.onOpen,
  });
  final CommunityWork work;
  final Set<String> saved;
  final void Function(Map<String, dynamic>) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topRated = avgRating(work.best) > 0;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CommunityCover(
                  title: work.title,
                  size: 48,
                  imageUrl: communityCoverUrl(work.best),
                  pngUrl: communityCoverUrl(work.best, ext: 'png'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        work.title,
                        style: theme.textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        work.author.isEmpty ? 'Unknown author' : work.author,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(
                    '${work.editions.length} versions',
                    style: const TextStyle(fontSize: 11),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const Divider(height: 16),
            for (var i = 0; i < work.editions.length; i++)
              InkWell(
                onTap: () => onOpen(work.editions[i]),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              submitterLabel(work.editions[i]),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '${formatDuration(((work.editions[i]['totalDurationMs'] ?? 0) as num).toInt())}'
                              '${_licenseOf(work.editions[i]).isEmpty ? '' : ' · ${_licenseOf(work.editions[i])}'}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      if (i == 0 && topRated)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: Chip(
                            label: Text(
                              'Top rated',
                              style: TextStyle(fontSize: 11),
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      if (saved.contains(work.editions[i]['id']))
                        const Icon(Icons.bookmark_rounded, size: 16),
                      _RatingText(work.editions[i]),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
