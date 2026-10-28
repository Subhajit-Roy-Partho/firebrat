import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/auth_service.dart';
import '../services/community_service.dart';
import '../utils/community_helpers.dart';

const communityBase =
    'https://subhajit-roy-partho.github.io/firebrat/community';

/// The package's own cover image (the Internet Archive serves files from inside the zip), or
/// null when the listing has no Archive item. Mirrors `coverUrl` in `community/src/ia.js`.
String? communityCoverUrl(Map<String, dynamic> data, {String ext = 'jpg'}) {
  final id = data['archiveId'] as String?;
  if (id == null || !archiveIdPattern.hasMatch(id)) return null;
  final zip = data['packageFile'] as String?;
  final inner = (data['packageKind'] == 'zip' && zip != null && zip.isNotEmpty)
      ? '${Uri.encodeComponent(id)}/${Uri.encodeComponent(zip)}/cover.$ext'
      : '${Uri.encodeComponent(id)}/cover.$ext';
  return 'https://archive.org/download/$inner';
}

/// Cover thumbnail: the package's real cover when it loads, else a deterministic
/// gradient with the title's first letter.
class CommunityCover extends StatelessWidget {
  const CommunityCover({
    super.key,
    required this.title,
    required this.size,
    this.imageUrl,
    this.pngUrl,
  });
  final String title;
  final double size;
  final String? imageUrl;

  /// Tried when [imageUrl] fails: packages ship cover.jpg or cover.png.
  final String? pngUrl;

  @override
  Widget build(BuildContext context) {
    final letter = title.trim().isEmpty ? '?' : title.trim()[0].toUpperCase();
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: coverColors(title),
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
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
    final url = imageUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: size,
        height: size,
        child: url == null ? fallback : _net(url, fallback, then: pngUrl),
      ),
    );
  }

  Widget _net(String url, Widget fallback, {String? then}) => Image.network(
    url,
    width: size,
    height: size,
    fit: BoxFit.cover,
    alignment: Alignment.topCenter,
    cacheWidth: (size * 3).round(), // decode small: covers are ~800px wide
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => then == null ? fallback : _net(then, fallback),
    loadingBuilder: (_, child, progress) => progress == null ? child : fallback,
  );
}

/// "Submitted by Name" (the launch catalogue is submitted by "Firebrat").
String submitterLabel(Map<String, dynamic> data) {
  final n = (data['submitterName'] as String?)?.trim() ?? '';
  return n.isEmpty ? 'Submitted by a community member' : 'Submitted by $n';
}

/// Read-only or tappable row of five stars.
class StarRow extends StatelessWidget {
  const StarRow({super.key, required this.value, this.onRate, this.size = 20});
  final double value;
  final ValueChanged<int>? onRate;
  final double size;

  @override
  Widget build(BuildContext context) {
    final rounded = value.round();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          onRate == null
              ? Icon(
                  i <= rounded
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  size: size,
                )
              : IconButton(
                  tooltip: 'Rate $i star${i > 1 ? 's' : ''}',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(
                    minWidth: size + 14,
                    minHeight: size + 14,
                  ),
                  iconSize: size + 6,
                  onPressed: () => onRate!(i),
                  icon: Icon(
                    i <= rounded
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                  ),
                ),
      ],
    );
  }
}

/// Bottom sheet for one community book: details, provenance, bookmark, star
/// rating and public reviews. Rating, reviewing and bookmarking need a sign-in.
class CommunityDetailSheet extends StatefulWidget {
  const CommunityDetailSheet({
    super.key,
    required this.bookId,
    required this.data,
    required this.onAdd,
  });
  final String bookId;
  final Map<String, dynamic> data;
  final VoidCallback onAdd;

  @override
  State<CommunityDetailSheet> createState() => _CommunityDetailSheetState();
}

class _CommunityDetailSheetState extends State<CommunityDetailSheet> {
  final _svc = CommunityService.instance;
  final _review = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _review.dispose();
    super.dispose();
  }

  void _say(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (done != null) _say(done);
    } on CommunityException catch (e) {
      _say(e.message);
    } on FirebaseException catch (e) {
      _say(
        e.code == 'permission-denied'
            ? 'Not allowed — sign in and try again.'
            : 'Could not save: ${e.message ?? e.code}',
      );
    } catch (e) {
      _say('Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() => _run(() async {
    await AuthService.instance.signInWithGoogle();
  }, done: 'Signed in');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        // Live copy of the book so the average updates right after you rate it.
        stream: FirebaseFirestore.instance
            .collection('books')
            .doc(widget.bookId)
            .snapshots(),
        builder: (context, bookSnap) {
          final data = bookSnap.data?.data() ?? widget.data;
          final title = data['title'] as String? ?? widget.bookId;
          final provenance =
              (data['provenance'] as Map<String, dynamic>?) ?? {};
          final count = ((data['ratingCount'] ?? 0) as num).toInt();
          final avg = ratingAverage((data['ratingSum'] ?? 0) as num, count);
          return StreamBuilder<User?>(
            stream: _svc.authChanges(),
            initialData: _svc.user,
            builder: (context, authSnap) {
              final user = authSnap.data;
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  20,
                  8,
                  20,
                  24 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        CommunityCover(
                          title: title,
                          size: 56,
                          imageUrl: communityCoverUrl(data),
                          pngUrl: communityCoverUrl(data, ext: 'png'),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: theme.textTheme.titleLarge),
                              Text(
                                (data['author'] as String? ?? '').isEmpty
                                    ? 'Unknown author'
                                    : data['author'] as String,
                                style: theme.textTheme.bodyMedium,
                              ),
                              Text(
                                submitterLabel(data),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        if (user != null) _bookmarkButton(),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Chip(
                          label: Text(
                            (data['license'] as String?) ??
                                (provenance['license'] as String?) ??
                                'unknown',
                          ),
                        ),
                        Chip(
                          avatar: const Icon(Icons.star_rounded, size: 16),
                          label: Text('${avg.toStringAsFixed(1)} ($count)'),
                        ),
                        Chip(
                          label: Text(
                            formatDuration(
                              ((data['totalDurationMs'] ?? 0) as num).toInt(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if ((data['description'] as String?)?.isNotEmpty ==
                        true) ...[
                      const SizedBox(height: 12),
                      Text(data['description'] as String),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onAdd();
                      },
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add to my library'),
                    ),
                    const SizedBox(height: 16),
                    _ratingSection(user),
                    const SizedBox(height: 16),
                    Text(
                      'How this audio was made',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    ..._provenanceRows(provenance, data),
                    const SizedBox(height: 16),
                    _reviewsSection(
                      user,
                      ((data['commentCount'] ?? 0) as num).toInt(),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => launchUrl(
                            Uri.parse('$communityBase/#/book/${widget.bookId}'),
                            mode: LaunchMode.externalApplication,
                          ),
                          icon: const Icon(Icons.public_rounded),
                          label: const Text('Open on website'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(
                                text: '$communityBase/#/book/${widget.bookId}',
                              ),
                            );
                            _say('Link copied');
                          },
                          icon: const Icon(Icons.share_outlined),
                          label: const Text('Copy link'),
                        ),
                        TextButton.icon(
                          onPressed: () => launchUrl(
                            Uri.parse(
                              '$communityBase/#/legal/takedown?book=${widget.bookId}',
                            ),
                            mode: LaunchMode.externalApplication,
                          ),
                          icon: const Icon(Icons.flag_outlined),
                          label: const Text('Report concern'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _bookmarkButton() {
    return StreamBuilder<Set<String>>(
      stream: _svc.favorites(),
      builder: (context, snap) {
        final saved = snap.data?.contains(widget.bookId) ?? false;
        return IconButton(
          tooltip: saved ? 'Remove bookmark' : 'Bookmark this book',
          onPressed: _busy
              ? null
              : () => _run(
                  () => _svc.setFavorite(widget.bookId, !saved),
                  done: saved ? 'Removed from your bookmarks' : 'Bookmarked',
                ),
          icon: Icon(
            saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          ),
        );
      },
    );
  }

  Widget _signInPrompt(String what) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(child: Text('Sign in to $what.')),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _signIn,
              icon: const Icon(Icons.login_rounded),
              label: const Text('Sign in with Google'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ratingSection(User? user) {
    final theme = Theme.of(context);
    if (user == null) {
      return _signInPrompt('rate, review and bookmark this book');
    }
    return StreamBuilder<int?>(
      stream: _svc.myRating(widget.bookId),
      builder: (context, snap) {
        final mine = snap.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              mine == null ? 'Rate this book' : 'Your rating',
              style: theme.textTheme.titleMedium,
            ),
            StarRow(
              value: (mine ?? 0).toDouble(),
              size: 30,
              onRate: _busy
                  ? null
                  : (v) => _run(
                      () => _svc.rate(widget.bookId, v),
                      done: 'Thanks — rated $v★',
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _reviewsSection(User? user, int total) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          total > 0 ? 'Reviews ($total)' : 'Reviews',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (user == null)
          _signInPrompt('write a review')
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _review,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 2000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Share what you thought…',
                    border: OutlineInputBorder(),
                    isDense: true,
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await _svc.addReview(widget.bookId, _review.text);
                        _review.clear();
                        if (mounted) FocusScope.of(context).unfocus();
                      }, done: 'Review posted'),
                child: const Text('Post'),
              ),
            ],
          ),
        const SizedBox(height: 8),
        StreamBuilder<List<CommunityReview>>(
          stream: _svc.reviews(widget.bookId),
          builder: (context, snap) {
            if (snap.hasError) {
              return Text(
                'Could not load reviews.',
                style: theme.textTheme.bodySmall,
              );
            }
            final list = snap.data;
            if (list == null) return const LinearProgressIndicator();
            if (list.isEmpty) {
              return Text(
                'No reviews yet — be the first.',
                style: theme.textTheme.bodySmall,
              );
            }
            return Column(
              children: [
                for (final r in list)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      r.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(r.text),
                    trailing: user == null
                        ? null
                        : r.uid == user.uid
                        ? IconButton(
                            tooltip: 'Delete my review',
                            icon: const Icon(Icons.delete_outline_rounded),
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    () =>
                                        _svc.deleteReview(widget.bookId, r.id),
                                    done: 'Review deleted',
                                  ),
                          )
                        : IconButton(
                            tooltip: 'Report this review',
                            icon: const Icon(Icons.flag_outlined),
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    () => _svc.reportReview(
                                      widget.bookId,
                                      r.id,
                                      'other',
                                    ),
                                    done:
                                        'Reported — an admin will take a look',
                                  ),
                          ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  List<Widget> _provenanceRows(
    Map<String, dynamic> provenance,
    Map<String, dynamic> data,
  ) {
    final rows = <Widget>[];
    void row(String label, String? value) {
      if (value == null || value.isEmpty) return;
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: RichText(
            text: TextSpan(
              style: const TextStyle(color: Colors.grey, fontSize: 14),
              children: [
                TextSpan(
                  text: '$label: ',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                TextSpan(text: value),
              ],
            ),
          ),
        ),
      );
    }

    row('Generation', provenance['generation'] as String?);
    row('Narration engine', provenance['narrationEngine'] as String?);
    final models = provenance['models'];
    if (models is List && models.isNotEmpty) row('Models', models.join(', '));
    row('Pipeline notes', provenance['pipelineNotes'] as String?);
    row(
      'Source',
      (provenance['sourceTitle'] as String?) ??
          (data['sourceTitle'] as String?),
    );
    row('Source URL', provenance['sourceUrl'] as String?);
    row(
      'License',
      (provenance['license'] as String?) ?? (data['license'] as String?),
    );
    row('License URL', provenance['licenseUrl'] as String?);
    if (rows.isEmpty) {
      rows.add(
        const Text(
          'No provenance details were provided for this book.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return rows;
  }
}
