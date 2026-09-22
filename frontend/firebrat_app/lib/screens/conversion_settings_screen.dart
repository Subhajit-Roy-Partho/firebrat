import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import '../models/book.dart';
import '../services/analytics_service.dart';
import '../services/drive_sync_service.dart';
import '../services/firestore_sync_service.dart';
import '../state/library_providers.dart';
import '../state/model_download_providers.dart';
import '../state/on_device_conversion_providers.dart';
import '../state/server_books_providers.dart';
import '../utils/server_url.dart';

/// The single place for "how do books get converted, narrated, and stored".
/// One scrollable page, three numbered sections, every field explained —
/// previously the cloud-LLM fields lived here while the local model and
/// voice hid on a second screen nobody found.
///
/// 1. Convert where — Firebrat server or this phone.
/// 2. Store finished books where — the server shelf, or your own Google
///    Drive (needs Drive sign-in; uses your quota; other devices pull).
/// 3. Narrate with what — system voice or on-device Kokoro + voice pick,
///    plus the local-LLM catalog (download) and GPU slider when relevant.
class ConversionSettingsScreen extends ConsumerStatefulWidget {
  const ConversionSettingsScreen({super.key});

  @override
  ConsumerState<ConversionSettingsScreen> createState() =>
      _ConversionSettingsScreenState();
}

class _ConversionSettingsScreenState
    extends ConsumerState<ConversionSettingsScreen> {
  late final TextEditingController _cloudUrlController;
  late final TextEditingController _llmUrlController;
  late final TextEditingController _llmKeyController;
  late final TextEditingController _llmModelController;
  bool _initialized = false;
  bool _driveBusy = false;
  String _driveStatus = '';

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
    if (settings.mode == ConversionModePref.cloud &&
        settings.cloudServerUrl.trim().isNotEmpty) {
      Future.microtask(() => ref.read(serverBooksProvider.notifier).check());
    }
    Future.microtask(_refreshDriveStatus);
  }

  Future<void> _refreshDriveStatus() async {
    final enabled = await DriveSyncService.instance.isEnabled();
    String status;
    if (!enabled) {
      status = 'Drive sync is off.';
    } else {
      try {
        final books = await DriveSyncService.instance.listBooks();
        status = 'Drive sync is on — ${books.length} book file(s) in your Firebrat folder.';
      } catch (e) {
        status = 'Drive needs attention: $e';
      }
    }
    if (mounted) setState(() => _driveStatus = status);
  }

  Future<void> _toggleDrive(bool on) async {
    setState(() {
      _driveBusy = true;
      _driveStatus = on ? 'Connecting to Drive…' : 'Turning off…';
    });
    try {
      if (on) {
        // Incremental consent: Drive scope is asked HERE, never at login.
        await DriveSyncService.instance.ensureAccess();
        await DriveSyncService.instance.setEnabled(true);
        await AnalyticsService.instance.logDriveSync(action: 'enabled');
      } else {
        await DriveSyncService.instance.setEnabled(false);
        await AnalyticsService.instance.logDriveSync(action: 'disabled');
      }
      await ref.read(conversionModeProvider.notifier).setStorageBackend(on ? 'drive' : 'server');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Drive setup failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _driveBusy = false);
      await _refreshDriveStatus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(conversionModeProvider);
    final notifier = ref.read(conversionModeProvider.notifier);
    _initControllersOnce(settings);
    final isCloud = settings.mode == ConversionModePref.cloud;

    return Scaffold(
      appBar: AppBar(title: const Text('Conversion settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionTitle('1 · Convert new books where?'),
          const _HelpText(
              'Cloud server converts with datacenter GPUs (fast, needs the server online). '
              'On this device converts with your phone (private, slower, needs the models below).'),
          const SizedBox(height: 8),
          SegmentedButton<ConversionModePref>(
            segments: const [
              ButtonSegment(
                  value: ConversionModePref.cloud,
                  label: Text('Cloud server'),
                  icon: Icon(Icons.cloud_outlined)),
              ButtonSegment(
                  value: ConversionModePref.onDevice,
                  label: Text('On this device'),
                  icon: Icon(Icons.phone_android_outlined)),
            ],
            selected: {settings.mode},
            onSelectionChanged: (s) => notifier.setMode(s.first),
          ),
          const SizedBox(height: 24),
          if (isCloud) ...[
            _SectionTitle('2 · Get finished books from where?'),
            const _HelpText(
                'Custom server reads the shelf at the URL below. Google Drive keeps your books '
                'in your own Drive (your quota, works across devices) — downloads back up there automatically.'),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: settings.storageBackend,
              onChanged: (v) {
                if (v == 'drive') {
                  _toggleDrive(true);
                } else if (v != null) {
                  notifier.setStorageBackend(v);
                }
              },
              child: Column(
                children: [
                  RadioListTile<String>(
                    title: const Text('Custom Firebrat server'),
                    subtitle: const Text('Shelf + downloads from the URL below.'),
                    value: 'server',
                  ),
                  RadioListTile<String>(
                    title: const Text('My Google Drive'),
                    subtitle: const Text('Books back up to your Drive; new devices pull them.'),
                    value: 'drive',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _DriveStatusRow(
              busy: _driveBusy,
              status: _driveStatus,
              enabled: settings.storageBackend == 'drive',
              onToggle: () => _toggleDrive(settings.storageBackend != 'drive'),
              onSyncNow: () => _syncFromDrive(context),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _cloudUrlController,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                helperText: 'Bare IPs work — http:// and :8000 are added for you.',
                hintText: 'http://100.87.251.5:8000',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
          ] else ...[
            _SectionTitle('2 · Cloud helper for hard chunks'),
            const _HelpText(
                'Easy chunks run on the local model below. Chunks with equations, figures, or tables '
                'still need one cloud LLM call each — any OpenAI-compatible endpoint (nano-gpt, OpenAI, …).'),
            const SizedBox(height: 12),
            TextField(
              controller: _llmUrlController,
              decoration: const InputDecoration(
                labelText: 'LLM URL',
                helperText: 'https:// is added for you if missing.',
                hintText: 'https://nano-gpt.com/api/v1',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _llmKeyController,
              decoration: const InputDecoration(
                labelText: 'API key',
                helperText: 'Stored only on this phone, sent only to the URL above.',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _llmModelController,
              decoration: const InputDecoration(
                labelText: 'Model name',
                helperText: 'Must be a thinking-capable model for math-heavy chunks.',
                hintText: 'deepseek/deepseek-v4-pro:thinking',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            _SectionTitle('3 · Local LLM (fully offline)'),
            const _HelpText(
                'Weights download straight from Hugging Face. Leaving this screen never stops a download — '
                'it resumes on its own, even after the app restarts.'),
            const SizedBox(height: 8),
            _LocalModelPicker(notifier: notifier, settings: settings),
          ],
          const SizedBox(height: 24),
          _SectionTitle(isCloud ? '3 · Narrator voice' : '4 · Narrator voice'),
          const _HelpText(
              'Who reads the book. System voice is instant; Kokoro is an on-device neural voice '
              '(voice data downloads on first use, ~300 MB). Server books keep the voice they were converted with.'),
          const SizedBox(height: 8),
          _VoicePicker(notifier: notifier, settings: settings),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => _save(context),
            child: const Text('Save'),
          ),
          if (isCloud) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),
            const _ServerBooksSection(),
          ],
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context) async {
    final settings = ref.read(conversionModeProvider);
    final notifier = ref.read(conversionModeProvider.notifier);
    if (settings.mode == ConversionModePref.cloud) {
      // Normalize first so a bare `100.87.251.5` becomes
      // `http://100.87.251.5:8000` — and write it back into the
      // field so the user sees the scheme/port appear.
      final normalized = normalizeServerUrl(_cloudUrlController.text);
      _cloudUrlController.text = normalized;
      await notifier.setCloudServerUrl(normalized);
      await ref.read(serverBooksProvider.notifier).check();
    } else {
      final normalizedUrl = normalizeLlmUrl(_llmUrlController.text);
      _llmUrlController.text = normalizedUrl;
      await notifier.setOnDeviceLlm(
        url: normalizedUrl,
        apiKey: _llmKeyController.text.trim(),
        model: _llmModelController.text.trim(),
      );
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    }
  }

  /// Pull every Drive book zip missing locally, then register each in
  /// Firestore so other devices learn about it.
  Future<void> _syncFromDrive(BuildContext context) async {
    setState(() {
      _driveBusy = true;
      _driveStatus = 'Listing your Drive folder…';
    });
    try {
      final svc = DriveSyncService.instance;
      await svc.ensureAccess();
      final remote = await svc.listBooks();
      final dm = ref.read(downloadManagerProvider);
      var pulled = 0;
      for (final f in remote) {
        if (!f.name.endsWith('.zip')) continue;
        final bookId = f.name.substring(0, f.name.length - 4);
        if (await dm.isDownloaded(bookId)) continue;
        setState(() => _driveStatus = 'Pulling $bookId…');
        final booksDir = (await dm.booksDir()).path;
        final zipPath = '$booksDir/$bookId.zip';
        await svc.downloadBook(driveFileId: f.id, destPath: zipPath);
        await dm.extractZipToBook(zipPath, await dm.bookDir(bookId));
        await FirestoreSyncService.instance.upsertBook(
          bookId: bookId,
          title: bookId,
          source: 'drive',
          sha256: f.sha256,
        );
        pulled++;
      }
      await AnalyticsService.instance.logDriveSync(action: 'sync_now');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(pulled == 0 ? 'Drive is in sync — nothing new.' : 'Pulled $pulled book(s) from Drive.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Drive sync failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _driveBusy = false);
      await _refreshDriveStatus();
    }
  }
}

class _HelpText extends StatelessWidget {
  final String text;
  const _HelpText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.bodySmall);
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.titleMedium);
  }
}

class _DriveStatusRow extends StatelessWidget {
  final bool busy;
  final String status;
  final bool enabled;
  final VoidCallback onToggle;
  final VoidCallback onSyncNow;

  const _DriveStatusRow({
    required this.busy,
    required this.status,
    required this.enabled,
    required this.onToggle,
    required this.onSyncNow,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_done_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status.isEmpty ? 'Drive sync is off.' : status,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (busy) const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton(
                  onPressed: busy ? null : onToggle,
                  child: Text(enabled ? 'Turn off' : 'Connect Drive'),
                ),
                if (enabled)
                  TextButton(
                    onPressed: busy ? null : onSyncNow,
                    child: const Text('Sync now'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalModelPicker extends ConsumerStatefulWidget {
  final ConversionModeNotifier notifier;
  final ConversionModeSettings settings;
  const _LocalModelPicker({required this.notifier, required this.settings});

  @override
  ConsumerState<_LocalModelPicker> createState() => _LocalModelPickerState();
}

class _LocalModelPickerState extends ConsumerState<_LocalModelPicker> {
  final Map<String, bool> _downloaded = {};

  @override
  void initState() {
    super.initState();
    _refreshDownloaded();
  }

  Future<void> _refreshDownloaded() async {
    final dir = await ModelDownloadNotifier.modelsDir();
    final result = <String, bool>{};
    for (final m in kOnDeviceLlmCatalog) {
      final f = File('$dir/${m.fileName}');
      result[m.id] = await f.exists() &&
          ((await f.length()) - m.approxSizeBytes).abs() < m.approxSizeBytes * 0.02;
    }
    if (mounted) setState(() => _downloaded.addAll(result));
  }

  static String _gb(int bytes) => '${(bytes / 1073741824).toStringAsFixed(1)} GB';

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final notifier = widget.notifier;
    final selected = findOnDeviceLlmModel(settings.onDeviceLlmModelId);
    final dl = ref.watch(modelDownloadProvider)[selected.id];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: selected.id,
          decoration: const InputDecoration(
            labelText: 'Model',
            helperText: 'Smaller = less RAM, weaker math. Bigger = slower download, better narration.',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final m in kOnDeviceLlmCatalog)
              DropdownMenuItem(
                value: m.id,
                child: Text(
                  '${m.displayName} · ${_gb(m.approxSizeBytes)} · ~${m.approxRamGb.toStringAsFixed(1)} GB RAM',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (id) {
            if (id != null) notifier.setLocalLlmModel(id);
          },
        ),
        const SizedBox(height: 4),
        Text(selected.description, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        if (dl != null && dl.downloading) ...[
          if (dl.fraction != null)
            LinearProgressIndicator(value: dl.fraction!.clamp(0.0, 1.0))
          else
            const LinearProgressIndicator(),
          Row(
            children: [
              Expanded(child: Text(dl.label, style: Theme.of(context).textTheme.bodySmall)),
              TextButton.icon(
                onPressed: () =>
                    ref.read(modelDownloadProvider.notifier).pauseDownload(selected.id),
                icon: const Icon(Icons.pause_rounded, size: 18),
                label: const Text('Pause'),
              ),
            ],
          ),
        ] else if (!(_downloaded[selected.id] ?? false)) ...[
          FilledButton.icon(
            onPressed: () async {
              try {
                await ref
                    .read(modelDownloadProvider.notifier)
                    .startDownload(selected);
                await _refreshDownloaded();
                await AnalyticsService.instance
                    .logModelDownloaded(modelId: selected.id);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Model download failed: $e')),
                  );
                }
              }
            },
            icon: Icon(dl != null && dl.receivedBytes > 0
                ? Icons.play_arrow_rounded
                : Icons.download_rounded),
            label: Text(dl != null && dl.receivedBytes > 0
                ? 'Resume ${dl.label}'
                : 'Download ${_gb(selected.approxSizeBytes)}'),
          ),
        ] else ...[
          const Chip(
            avatar: Icon(Icons.check_circle_rounded, size: 18),
            label: Text('Downloaded'),
          ),
        ],
        const SizedBox(height: 12),
        Text('Device acceleration', style: Theme.of(context).textTheme.titleSmall),
        const Text(
          'Transformer layers offloaded to the GPU. 99 pushes everything that fits (fastest); '
          '0 forces pure CPU if the GPU driver misbehaves (slow but safe).',
          style: TextStyle(fontSize: 12),
        ),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: settings.onDeviceGpuLayers.toDouble(),
                min: 0,
                max: 99,
                divisions: 99,
                label: '${settings.onDeviceGpuLayers}',
                onChanged: (v) => notifier.setGpuLayers(v.round()),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text('${settings.onDeviceGpuLayers}',
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ],
        ),
      ],
    );
  }
}

class _VoicePicker extends StatelessWidget {
  final ConversionModeNotifier notifier;
  final ConversionModeSettings settings;
  const _VoicePicker({required this.notifier, required this.settings});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        RadioGroup<String>(
          groupValue: settings.voiceEngine,
          onChanged: (v) {
            if (v != null) notifier.setVoiceEngine(v);
          },
          child: Column(
            children: [
              RadioListTile<String>(
                title: const Text('System voice'),
                subtitle: const Text('Your phone\u2019s built-in voice. Zero downloads, instant start.'),
                value: 'stockTts',
              ),
              RadioListTile<String>(
                title: const Text('Kokoro (on-device neural)'),
                subtitle: const Text('Natural neural voice, fully offline. Voice data (~300 MB) downloads on first use.'),
                value: 'kokoroOnnx',
              ),
            ],
          ),
        ),
        if (settings.isKokoroVoice)
          DropdownButtonFormField<String>(
            initialValue: kKokoroVoices.contains(settings.kokoroVoice)
                ? settings.kokoroVoice
                : kKokoroVoices.first,
            decoration: const InputDecoration(
              labelText: 'Kokoro voice',
              helperText: '50 presets — names hint at character, all speak the same text.',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final v in kKokoroVoices) DropdownMenuItem(value: v, child: Text(v)),
            ],
            onChanged: (v) {
              if (v != null) notifier.setKokoroVoice(v);
            },
          ),
      ],
    );
  }
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
