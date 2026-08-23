import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/book.dart';
import '../state/on_device_conversion_providers.dart';
import '../state/server_books_providers.dart';

/// The one choice this app needs from the user for "how do I convert a new
/// book": send it to a Firebrat server, or convert it on this device. Cloud
/// mode needs just the server's URL — entering/saving one checks
/// reachability and lists what's already converted there, with a delete
/// action to free server space. On-device mode needs an OpenAI-compatible
/// LLM endpoint (url/key/model) for the chunks the on-device model routes
/// to the cloud — see `mobile-Backend/PROPOSAL.md` §5.
class ConversionSettingsScreen extends ConsumerStatefulWidget {
  const ConversionSettingsScreen({super.key});

  @override
  ConsumerState<ConversionSettingsScreen> createState() => _ConversionSettingsScreenState();
}

class _ConversionSettingsScreenState extends ConsumerState<ConversionSettingsScreen> {
  late final TextEditingController _cloudUrlController;
  late final TextEditingController _llmUrlController;
  late final TextEditingController _llmKeyController;
  late final TextEditingController _llmModelController;
  bool _initialized = false;

  @override
  void dispose() {
    _cloudUrlController.dispose();
    _llmUrlController.dispose();
    _llmKeyController.dispose();
    _llmModelController.dispose();
    super.dispose();
  }

  void _initControllersOnce(ConversionModeSettings settings) {
    if (_initialized) return;
    _initialized = true;
    _cloudUrlController = TextEditingController(text: settings.cloudServerUrl);
    _llmUrlController = TextEditingController(text: settings.onDeviceLlmUrl);
    _llmKeyController = TextEditingController(text: settings.onDeviceLlmApiKey);
    _llmModelController = TextEditingController(text: settings.onDeviceLlmModel);
    // Check the already-saved server, if any, the moment this screen opens
    // — the user shouldn't have to hit Save just to see whether it's reachable.
    if (settings.mode == ConversionModePref.cloud && settings.cloudServerUrl.trim().isNotEmpty) {
      Future.microtask(() => ref.read(serverBooksProvider.notifier).check());
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(conversionModeProvider);
    final notifier = ref.read(conversionModeProvider.notifier);
    _initControllersOnce(settings);

    return Scaffold(
      appBar: AppBar(title: const Text('Conversion settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('How should new books be converted?', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<ConversionModePref>(
            segments: const [
              ButtonSegment(value: ConversionModePref.cloud, label: Text('Cloud server'), icon: Icon(Icons.cloud_outlined)),
              ButtonSegment(value: ConversionModePref.onDevice, label: Text('On this device'), icon: Icon(Icons.phone_android_outlined)),
            ],
            selected: {settings.mode},
            onSelectionChanged: (s) => notifier.setMode(s.first),
          ),
          const SizedBox(height: 24),
          if (settings.mode == ConversionModePref.cloud) ..._cloudFields() else ..._onDeviceFields(),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () async {
              if (settings.mode == ConversionModePref.cloud) {
                await notifier.setCloudServerUrl(_cloudUrlController.text.trim());
                await ref.read(serverBooksProvider.notifier).check();
              } else {
                await notifier.setOnDeviceLlm(
                  url: _llmUrlController.text.trim(),
                  apiKey: _llmKeyController.text.trim(),
                  model: _llmModelController.text.trim(),
                );
              }
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
              }
            },
            child: const Text('Save'),
          ),
          if (settings.mode == ConversionModePref.cloud) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),
            const _ServerBooksSection(),
          ],
        ],
      ),
    );
  }

  List<Widget> _cloudFields() => [
        Text(
          'Books you upload are sent to this Firebrat server, which does extraction, narration, and everything else.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _cloudUrlController,
          decoration: const InputDecoration(labelText: 'Server URL', hintText: 'http://100.87.251.5:8000', border: OutlineInputBorder()),
          keyboardType: TextInputType.url,
        ),
      ];

  List<Widget> _onDeviceFields() => [
        Text(
          'Extraction and narration run on this device. Chunks with equations, figures, or tables still need a cloud '
          'LLM call — point this at nano-gpt, OpenAI, or any other OpenAI-compatible endpoint.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _llmUrlController,
          decoration: const InputDecoration(
            labelText: 'LLM URL',
            hintText: 'https://nano-gpt.com/api/v1',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _llmKeyController,
          decoration: const InputDecoration(labelText: 'API key', border: OutlineInputBorder()),
          obscureText: true,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _llmModelController,
          decoration: const InputDecoration(
            labelText: 'Model name',
            hintText: 'deepseek/deepseek-v4-pro:thinking',
            border: OutlineInputBorder(),
          ),
        ),
      ];
}

class _ServerBooksSection extends ConsumerWidget {
  const _ServerBooksSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(serverBooksProvider);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Server library', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Re-check connection',
              onPressed: state.checking ? null : () => ref.read(serverBooksProvider.notifier).check(),
            ),
          ],
        ),
        if (state.checking)
          const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: CircularProgressIndicator()))
        else if (state.connected == null)
          const Text('Not checked yet.')
        else if (state.connected == false)
          Row(
            children: [
              Icon(Icons.error_outline_rounded, color: scheme.error, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(state.error ?? 'Could not reach this server.', style: TextStyle(color: scheme.error))),
            ],
          )
        else ...[
          Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.green, size: 18),
              const SizedBox(width: 8),
              Text('Connected — ${state.books.length} book${state.books.length == 1 ? '' : 's'} on the server'),
            ],
          ),
          if (state.error != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(state.error!, style: TextStyle(color: scheme.error))),
          const SizedBox(height: 8),
          for (final book in state.books) _ServerBookTile(book: book),
        ],
      ],
    );
  }
}

class _ServerBookTile extends ConsumerWidget {
  final BookSummary book;
  const _ServerBookTile({required this.book});

  String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${book.sectionCount} sections · ${_formatSize(book.sizeBytes)}'),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline_rounded),
          tooltip: 'Delete from server',
          onPressed: () => _confirmDelete(context, ref),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete from server?'),
        content: Text('"${book.title}" will be permanently removed from the server to free up space. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(serverBooksProvider.notifier).deleteBook(book.bookId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Deleted "${book.title}" from the server')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }
}
