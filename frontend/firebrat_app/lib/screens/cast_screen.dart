import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/cast_provider.dart';

/// Lets a reader check what the conversion found in a novel: every speaker, how
/// many lines each has, how much of the dialogue was attributed at all, and the
/// age, temperament and voice each character was given.
class CastScreen extends ConsumerWidget {
  final String bookId;
  const CastScreen({super.key, required this.bookId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cast = ref.watch(castProvider(bookId));
    return Scaffold(
      appBar: AppBar(title: const Text('Cast & voices')),
      body: cast.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const _NoCast(),
        data: (data) => data == null ? const _NoCast() : _CastBody(data: data),
      ),
    );
  }
}

class _NoCast extends StatelessWidget {
  const _NoCast();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No cast was recorded for this book. It is saved when a book is converted in Novel mode.',
            textAlign: TextAlign.center,
          ),
        ),
      );
}

class _CastBody extends StatelessWidget {
  final CastData data;
  const _CastBody({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pct = (data.coverage * 100).round();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${data.characters.length} speakers found', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                if (data.dialogueTotal > 0) ...[
                  Text('${data.dialogueAttributed} of ${data.dialogueTotal} spoken lines ($pct%) are attributed to a named speaker. '
                      'The other ${data.dialogueTotal - data.dialogueAttributed} are read by the narrator.'),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(value: data.coverage, minHeight: 8),
                  ),
                ] else
                  const Text('No quoted dialogue was found in this book.'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ExpansionTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('How to check this against the book'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('• A character appears here only when the book tags their lines, for example "Elizabeth said" or '
                  '"said Mr. Darcy". Lines without a tag are read by the narrator, so the percentage above is the real measure of coverage.'),
              SizedBox(height: 6),
              Text('• Compare this list with the people you expect, and look at the line counts: the main characters should have the most.'),
              SizedBox(height: 6),
              Text('• A missing character usually just never has a tagged line. A wrong name (a title or place) can be corrected in '
                  'Conversion settings under Character voice overrides, then convert again.'),
            ],
          ),
        ),
        if (data.researchStatus != null) ...[
          const SizedBox(height: 8),
          Card(
            color: data.researchStatus == 'applied' ? scheme.secondaryContainer : scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(data.researchStatus == 'applied' ? Icons.travel_explore_rounded : Icons.info_outline_rounded),
                    const SizedBox(width: 8),
                    Text(data.researchStatus == 'applied' ? 'Web research used' : 'Web research skipped',
                        style: theme.textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 6),
                  if (data.researchStatus == 'applied') ...[
                    Text('${data.described} of ${data.characters.length} characters were described from ${data.articles.join(' and ')} on Wikipedia.'),
                    if (data.notDescribed.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('Not described: ${data.notDescribed.join(', ')}.'),
                      ),
                  ] else
                    Text(data.researchReason ?? 'No reason was recorded.'),
                ],
              ),
            ),
          ),
        ],
        if (data.unmatchedOverrides.isNotEmpty) ...[
          const SizedBox(height: 8),
          Card(
            color: scheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Overrides that matched nobody: ${data.unmatchedOverrides.join(', ')}. '
                  'Check the spelling against the names below.'),
            ),
          ),
        ],
        const SizedBox(height: 12),
        for (final c in data.characters) _CharacterTile(character: c),
      ],
    );
  }
}

class _CharacterTile extends StatelessWidget {
  final CastCharacter character;
  const _CharacterTile({required this.character});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = character;
    final chips = <String>[
      if (c.gender != 'unknown') c.gender,
      if (c.age != 'unknown') c.age,
      if (c.temperament != 'unknown') c.temperament,
    ];
    final source = switch (c.traitSource) {
      'web' => ' · from web research',
      'user' => ' · set by you',
      _ => '',
    };
    return ListTile(
      key: ValueKey('cast-${c.name}'),
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(child: Text(c.name.isEmpty ? '?' : c.name[0].toUpperCase())),
      title: Text(c.name, style: theme.textTheme.titleMedium),
      subtitle: Text(
        '${c.lines} ${c.lines == 1 ? 'line' : 'lines'}'
        '${c.firstPage != null ? ' · first on page ${c.firstPage}' : ''}'
        '\n${chips.isEmpty ? 'traits unknown' : chips.join(', ')}$source'
        '\nVoice: ${c.voice}',
      ),
      isThreeLine: true,
    );
  }
}
