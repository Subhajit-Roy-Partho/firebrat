import 'dart:io';
import 'package:file_picker/file_picker.dart';
import '../widgets/kokoro_model_controls.dart';
import '../widgets/model_choice_widgets.dart';
import '../services/device_probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import '../models/book.dart';
import '../services/analytics_service.dart';
import '../services/drive_sync_service.dart';
import '../services/firestore_sync_service.dart';
import 'sync_screen.dart';
import 'llm_key_guide_screen.dart';
import 'server_admin_screen.dart';
import 'tour_screen.dart';
import '../state/library_providers.dart';
import '../state/server_admin_providers.dart';
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
  late final TextEditingController _serverLlmUrlController;
  late final TextEditingController _serverLlmKeyController;
  late final TextEditingController _serverLlmModelController;
  bool _initialized = false;
  bool _driveBusy = false;
  String _driveStatus = '';

  @override
  void dispose() {
    _cloudUrlController.dispose();
    _llmUrlController.dispose();
    _llmKeyController.dispose();
    _llmModelController.dispose();
    _serverLlmUrlController.dispose();
    _serverLlmKeyController.dispose();
    _serverLlmModelController.dispose();
    super.dispose();
  }

  void _initControllersOnce(ConversionModeSettings settings) {
    if (_initialized) return;
    _initialized = true;
    _cloudUrlController = TextEditingController(text: settings.cloudServerUrl);
    _llmUrlController = TextEditingController(text: settings.onDeviceLlmUrl);
    _llmKeyController = TextEditingController(text: settings.onDeviceLlmApiKey);
    _llmModelController = TextEditingController(
      text: settings.onDeviceLlmModel,
    );
    _serverLlmUrlController = TextEditingController(
      text: settings.serverLlmUrl,
    );
    _serverLlmKeyController = TextEditingController(
      text: settings.serverLlmApiKey,
    );
    _serverLlmModelController = TextEditingController(
      text: settings.serverLlmModel,
    );
    // Check the already-saved server, if any, the moment this screen opens
    // — the user shouldn't have to hit Save just to see whether it's reachable.
    if (settings.mode == ConversionModePref.cloud &&
        settings.cloudServerUrl.trim().isNotEmpty) {
      Future.microtask(() => ref.read(serverBooksProvider.notifier).check());
    }
    Future.microtask(_refreshDriveStatus);
  }

  Future<void> _refreshDriveStatus() async {
    if (ref.read(conversionModeProvider).mode != ConversionModePref.cloud) {
      return;
    }
    final enabled = await DriveSyncService.instance.isEnabled();
    String status;
    if (!enabled) {
      status = 'Drive sync is off.';
    } else {
      try {
        final books = await DriveSyncService.instance.listBooks();
        status =
            'Drive sync is on — ${books.length} book file(s) in your Firebrat folder.';
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
      await ref
          .read(conversionModeProvider.notifier)
          .setStorageBackend(on ? 'drive' : 'server');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Drive setup failed: ${_displayError(e)}')),
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
      appBar: AppBar(
        title: const Text('Conversion settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.explore_outlined),
            tooltip: 'App guide',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const TourScreen())),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionTitle('1 · How do you want to use Firebrat?'),
          const _HelpText(
            'Offline reads and plays imported books with no server or account. '
            'Cloud server converts with datacenter GPUs (fast, needs the server online). '
            'On this device converts with your phone (private, slower, needs the models below).',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in const [
                (
                  ConversionModePref.offline,
                  'Offline',
                  Icons.offline_pin_outlined,
                ),
                (ConversionModePref.cloud, 'Server', Icons.cloud_outlined),
                (
                  ConversionModePref.onDevice,
                  'On-device',
                  Icons.phone_android_outlined,
                ),
              ])
                ChoiceChip(
                  avatar: Icon(option.$3, size: 18),
                  label: Text(option.$2),
                  selected: settings.mode == option.$1,
                  onSelected: (_) => notifier.setMode(option.$1),
                ),
            ],
          ),
          const SizedBox(height: 24),
          if (settings.mode != ConversionModePref.offline) ...[
            _SectionTitle('2 · Book type'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Illustrated / technical'),
                  selected: settings.contentMode == 'illustrated',
                  onSelected: (_) => notifier.setContentMode('illustrated'),
                ),
                ChoiceChip(
                  label: const Text('Novel / characters'),
                  selected: settings.contentMode == 'novel',
                  onSelected: (_) => notifier.setContentMode('novel'),
                ),
                if (settings.mode == ConversionModePref.onDevice &&
                    CastLimits.allowedFor(
                        (ref.watch(deviceCapabilitiesProvider).asData?.value ?? DeviceCapabilities.unknown).tier))
                  ChoiceChip(
                    label: const Text('Expressive (experimental)'),
                    selected: settings.contentMode == 'expressive',
                    onSelected: (_) => notifier.setContentMode('expressive'),
                  ),
              ],
            ),
            if (settings.mode == ConversionModePref.onDevice && settings.contentMode == 'expressive')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ExpressiveModelControls(settings: settings, notifier: notifier),
              ),
            if (settings.contentMode == 'novel')
              const _HelpText(
                'Scans the whole book for explicitly named speakers, keeps the original prose, and assigns consistent character speaking styles. Uncertain speakers use the narrator. English named speech tags are supported; character aliases and pronouns are not inferred.',
              ),
            const SizedBox(height: 16),
          ],
          if (isCloud) ...[
            _SectionTitle('3 · Get finished books from where?'),
            const _HelpText(
              'Custom server reads the shelf at the URL below. Google Drive keeps your books '
              'in your own Drive (your quota, works across devices) — downloads back up there automatically.',
            ),
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
                    subtitle: const Text(
                      'Shelf + downloads from the URL below.',
                    ),
                    value: 'server',
                  ),
                  RadioListTile<String>(
                    title: const Text('My Google Drive'),
                    subtitle: const Text(
                      'Books back up to your Drive; new devices pull them.',
                    ),
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
                helperText:
                    'Bare IPs work — http:// and :8000 are added for you.',
                hintText: 'http://100.87.251.5:8000',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            _SectionTitle('Server conversion engine'),
            const _HelpText(
              'Native GPU converts with datacenter GPUs only. LLM helper '
              'matches the server default: hard passages go to a cloud model.',
            ),
            const SizedBox(height: 8),
            _ServerProviderPicker(notifier: notifier, settings: settings),
            if (settings.serverProvider != 'native') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _serverLlmUrlController,
                decoration: const InputDecoration(
                  labelText: 'Cloud LLM URL (optional override)',
                  helperText:
                      'Leave empty to use the server default. https:// is added for you if missing.',
                  hintText: 'https://nano-gpt.com/api/v1',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _serverLlmKeyController,
                decoration: const InputDecoration(
                  labelText: 'API key (optional)',
                  helperText:
                      'Stored only on this phone, sent only with your own uploads.',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              _ServerModelPicker(
                modelController: _serverLlmModelController,
                serverUrlController: _cloudUrlController,
              ),
              const SizedBox(height: 12),
              _EndpointTools(
                urlController: _serverLlmUrlController,
                keyController: _serverLlmKeyController,
                modelController: _serverLlmModelController,
              ),
            ],
          ] else if (settings.mode == ConversionModePref.onDevice) ...[
            _SectionTitle('Fully local conversion'),
            const _HelpText(
              'All passages are processed on this phone. Download the model and an offline voice once; no account, API key, or server is required after setup. Original page visuals preserve pictures and table layout alongside narration; precise figure cropping is not yet supported.',
            ),
            SwitchListTile(
              title: const Text('Allow cloud helper'),
              subtitle: const Text(
                'Optional: send difficult passages to your configured provider. Off keeps all conversion local.',
              ),
              value: settings.allowCloudFallback,
              onChanged: notifier.setAllowCloudFallback,
            ),
            // The LLM fields serve two jobs: the cloud helper (book text, opt-in)
            // and character research (title and names only, automatic in novels).
            if (settings.allowCloudFallback ||
                (settings.contentMode == 'novel' &&
                    settings.researchCharacters && !settings.localCharacterResearch)) ...[
              if (settings.allowCloudFallback)
                SwitchListTile(
                  title: const Text('Use the cloud LLM for every passage'),
                  subtitle: const Text(
                    'Faster, and no local model download. The text of the book is sent to your provider, so leave this off for private books.',
                  ),
                  value: settings.cloudForAll,
                  onChanged: notifier.setCloudForAll,
                ),
              _SectionTitle(
                !settings.allowCloudFallback
                    ? 'LLM for character research'
                    : settings.cloudForAll
                    ? 'Cloud LLM'
                    : 'Cloud helper for hard chunks',
              ),
              _HelpText(
                !settings.allowCloudFallback
                    ? 'Used only to describe the characters of a novel from its Wikipedia article. Only the book title and character names are sent, never the book\'s text. Any OpenAI-compatible endpoint works, including free keys from OpenRouter (https://openrouter.ai/api/v1), Groq or Google AI Studio.'
                    : settings.cloudForAll
                    ? 'Every passage goes to this provider, and no local model is downloaded. Any OpenAI-compatible '
                          'endpoint works, including free keys from OpenRouter (https://openrouter.ai/api/v1), Groq or Google AI Studio.'
                    : 'Easy chunks run on the local model below. Chunks with equations, figures, or tables '
                          'still need one cloud LLM call each — any OpenAI-compatible endpoint (nano-gpt, OpenAI, …).',
              ),
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
                  helperText:
                      'Stored only on this phone, sent only to the URL above.',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _llmModelController,
                decoration: const InputDecoration(
                  labelText: 'Model name',
                  helperText:
                      'Must be a thinking-capable model for math-heavy chunks.',
                  hintText: 'deepseek/deepseek-v4-pro:thinking',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              _EndpointTools(
                urlController: _llmUrlController,
                keyController: _llmKeyController,
                modelController: _llmModelController,
              ),
              const SizedBox(height: 24),
            ],
            if (!(settings.allowCloudFallback && settings.cloudForAll) || settings.localCharacterResearch) ...[
              _SectionTitle('3 · Local LLM (fully offline)'),
              const _HelpText(
                'Weights download straight from Hugging Face. Leaving this screen never stops a download — '
                'it resumes on its own, even after the app restarts.',
              ),
              const SizedBox(height: 8),
              _LocalModelPicker(notifier: notifier, settings: settings),
            ],
          ],
          if (settings.mode == ConversionModePref.offline)
            const _HelpText(
              'Import a .tar.gz or .zip book from your library. '
              'Reading and playback use files on this phone. Switch modes when you want to convert new books or use a server.',
            ),
          if (settings.mode != ConversionModePref.offline) ...[
            const SizedBox(height: 24),
            _SectionTitle(
              isCloud ? '3 · Narrator voice' : '4 · Narrator voice',
            ),
            const _HelpText(
              'Who reads the book. System voice is instant; Kokoro is an on-device neural voice '
              '(voice data downloads on first use, ~300 MB). Server books keep the voice they were converted with.',
            ),
            const SizedBox(height: 8),
            _VoicePicker(notifier: notifier, settings: settings),
          ],
          const SizedBox(height: 24),
          const _SectionTitle('Downloads'),
          const SizedBox(height: 4),
          const DownloadNetworkSetting(),
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
            // Admin-only: hidden for non-admins and while IAM is off
            // (unless the account is the legacy admin).
            const _ServerAdminSection(),
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
      final serverLlmUrl = _serverLlmUrlController.text.trim().isEmpty
          ? ''
          : normalizeLlmUrl(_serverLlmUrlController.text);
      _serverLlmUrlController.text = serverLlmUrl;
      await notifier.setServerLlm(
        url: serverLlmUrl,
        apiKey: _serverLlmKeyController.text.trim(),
        model: _serverLlmModelController.text.trim(),
      );
      // The home screen's catalog only refetches when invalidated — without
      // this, saving a new URL left stale titles (or the retry state) in
      // place until something else happened to refresh it.
      ref.invalidate(catalogProvider);
      await ref.read(serverBooksProvider.notifier).check();
      await ref.read(serverBooksProvider.notifier).refreshModels();
    } else if (settings.mode == ConversionModePref.onDevice) {
      final normalizedUrl = normalizeLlmUrl(_llmUrlController.text);
      _llmUrlController.text = normalizedUrl;
      await notifier.setOnDeviceLlm(
        url: normalizedUrl,
        apiKey: _llmKeyController.text.trim(),
        model: _llmModelController.text.trim(),
      );
    }
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Saved')));
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
          driveFileId: f.id,
        );
        pulled++;
      }
      await AnalyticsService.instance.logDriveSync(action: 'sync_now');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              pulled == 0
                  ? 'Drive is in sync — nothing new.'
                  : 'Pulled $pulled book(s) from Drive.',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Drive sync failed: ${_displayError(e)}')),
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

/// StateError already carries a human message (`Bad state: ...` adds
/// noise in a snackbar); anything else falls back to its toString.
String _displayError(Object e) => e is StateError ? e.message : '$e';

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
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
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
                // Per-book backup lives on Sync & backup; link it from here
                // so Drive users can reach it without going via the drawer.
                TextButton(
                  onPressed: busy
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const SyncScreen()),
                        ),
                  child: const Text('Per-book backup'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerProviderPicker extends StatelessWidget {
  final ConversionModeNotifier notifier;
  final ConversionModeSettings settings;
  const _ServerProviderPicker({required this.notifier, required this.settings});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(
          value: 'llm',
          label: Text('LLM helper'),
          icon: Icon(Icons.auto_awesome_outlined),
        ),
        ButtonSegment(
          value: 'native',
          label: Text('Native GPU'),
          icon: Icon(Icons.memory_outlined),
        ),
      ],
      selected: {settings.serverProvider == 'native' ? 'native' : 'llm'},
      showSelectedIcon: false,
      onSelectionChanged: (picked) => notifier.setServerProvider(picked.first),
    );
  }
}

/// Server model choice: a dropdown once GET /models (or the GET /settings
/// fallback) answers, otherwise a plain text field so an unreachable or
/// older server never blocks saving. The refresh button probes whatever is
/// currently in the Server URL field, saved or not.
class _ServerModelPicker extends ConsumerWidget {
  final TextEditingController modelController;
  final TextEditingController serverUrlController;
  const _ServerModelPicker({
    required this.modelController,
    required this.serverUrlController,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverState = ref.watch(serverBooksProvider);
    final models = serverState.models;
    final current = modelController.text.trim();

    Widget field;
    if (models.isNotEmpty) {
      final items = current.isNotEmpty && !models.contains(current)
          ? [current, ...models]
          : models;
      field = DropdownButtonFormField<String>(
        key: ValueKey('server-model-${models.join('|')}'),
        isExpanded: true,
        initialValue: current.isNotEmpty && items.contains(current)
            ? current
            : null,
        decoration: const InputDecoration(
          labelText: 'Model',
          helperText: 'Used for hard passages when the LLM helper is on.',
          helperMaxLines: 5,
          border: OutlineInputBorder(),
        ),
        items: [
          for (final m in items)
            DropdownMenuItem(
              value: m,
              child: Text(m, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) {
          if (v != null) modelController.text = v;
        },
      );
    } else {
      field = TextField(
        controller: modelController,
        decoration: const InputDecoration(
          labelText: 'Model name (optional)',
          helperText:
              'Empty uses the server default. Must be a thinking-capable model for math-heavy books.',
          hintText: 'deepseek/deepseek-v4-pro:thinking',
          border: OutlineInputBorder(),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field,
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                serverState.modelsLoading
                    ? 'Loading models…'
                    : (serverState.modelsError ??
                          (models.isEmpty
                              ? 'Models not loaded yet.'
                              : '${models.length} model${models.length == 1 ? '' : 's'} from the server.')),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton.icon(
              onPressed: serverState.modelsLoading
                  ? null
                  : () => ref
                        .read(serverBooksProvider.notifier)
                        .refreshModels(
                          baseUrlOverride: serverUrlController.text,
                        ),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Load models'),
            ),
          ],
        ),
      ],
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
    final dir = '${await ModelDownloadNotifier.modelsDir()}/llm';
    final result = <String, bool>{};
    for (final m in kOnDeviceLlmCatalog) {
      final f = File('$dir/${m.fileName}');
      result[m.id] =
          await f.exists() &&
          ((await f.length()) - m.approxSizeBytes).abs() <
              m.approxSizeBytes * 0.02;
    }
    if (mounted) setState(() => _downloaded.addAll(result));
  }

  static String _gb(int bytes) =>
      '${(bytes / 1073741824).toStringAsFixed(1)} GB';

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final notifier = widget.notifier;
    final selected = findOnDeviceLlmModel(settings.onDeviceLlmModelId);
    final dl = ref.watch(modelDownloadProvider)[selected.id];
    final caps = ref.watch(deviceCapabilitiesProvider).asData?.value ?? DeviceCapabilities.unknown;
    final recommended = recommendLlm(caps);
    final fit = assessFit(name: selected.displayName, minDeviceRamGb: selected.minDeviceRamGb, device: caps);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: selected.id,
          decoration: const InputDecoration(
            labelText: 'Model',
            helperText:
                'Smaller = less RAM, weaker math. Bigger = slower download, better narration.',
            helperMaxLines: 5,
            border: OutlineInputBorder(),
          ),
          items: [
            for (final m in llmModelsByTier())
              DropdownMenuItem(
                value: m.id,
                child: Semantics(
                  label: '${m.displayName}, ${m.tier.label}, ${_gb(m.approxSizeBytes)} download, needs about ${m.minDeviceRamGb.toStringAsFixed(0)} gigabytes of RAM',
                  excludeSemantics: true,
                  child: Text(
                    '${m.tier.label} · ${m.displayName} · ${_gb(m.approxSizeBytes)} · ${m.minDeviceRamGb.toStringAsFixed(m.minDeviceRamGb == m.minDeviceRamGb.roundToDouble() ? 0 : 1)} GB+ RAM',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
          onChanged: (id) {
            if (id != null) notifier.setLocalLlmModel(id);
          },
        ),
        const SizedBox(height: 4),
        Text(
          selected.description,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          '${selected.tier.label} class (${selected.tier.audience}) · ${selected.runtime} · '
          'GPU offload optional (CPU fallback) · Licence: ${selected.license}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (fit.warning != null) ...[
          NoticeCard(
            icon: Icons.memory_rounded,
            severe: fit.fit == ModelFit.tooLarge,
            text: fit.warning!,
          ),
          const SizedBox(height: 8),
        ],
        if (recommended.id != selected.id)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => notifier.setLocalLlmModel(recommended.id),
              icon: const Icon(Icons.recommend_outlined, size: 18),
              label: Text(caps.totalRamMb == null
                  ? 'Safe default: ${recommended.displayName}'
                  : 'Recommended for this phone (${caps.summary}): ${recommended.displayName}'),
            ),
          )
        else
          Text('Recommended for this phone (${caps.summary}).', style: Theme.of(context).textTheme.bodySmall),
        NoticeCard(
          icon: Icons.sd_storage_outlined,
          text: 'Download size ${_gb(selected.approxSizeBytes)}; keep at least '
              '${((selected.approxSizeBytes * 1.15) / 1073741824).toStringAsFixed(1)} GB of free storage. '
              '${const NetworkPolicy().recommendsWifi(selected.approxSizeBytes) ? 'Use Wi-Fi for this one. ' : ''}'
              'The file is checked against its SHA-256 after download.',
        ),
        const SizedBox(height: 8),
        const Align(alignment: Alignment.centerLeft, child: NetworkStatusChip()),
        if (dl != null && dl.waitingLabel != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Semantics(
              liveRegion: true,
              child: Text('${dl.waitingLabel} · partial download kept; resumes automatically.',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
        const SizedBox(height: 8),
        if (dl != null && dl.downloading) ...[
          if (dl.fraction != null)
            LinearProgressIndicator(value: dl.fraction!.clamp(0.0, 1.0))
          else
            const LinearProgressIndicator(),
          Row(
            children: [
              Expanded(
                child: Text(
                  dl.label,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton.icon(
                onPressed: () => ref
                    .read(modelDownloadProvider.notifier)
                    .pauseDownload(selected.id),
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
                await AnalyticsService.instance.logModelDownloaded(
                  modelId: selected.id,
                );
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Model download failed: $e')),
                  );
                }
              }
            },
            icon: Icon(
              dl != null && dl.receivedBytes > 0
                  ? Icons.play_arrow_rounded
                  : Icons.download_rounded,
            ),
            label: Text(
              dl != null && dl.receivedBytes > 0
                  ? 'Resume ${dl.label}'
                  : 'Download ${_gb(selected.approxSizeBytes)}',
            ),
          ),
        ] else ...[
          const Chip(
            avatar: Icon(Icons.check_circle_rounded, size: 18),
            label: Text('Downloaded'),
          ),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: dl?.downloading == true ? null : () async {
            try {
              final picked = await FilePicker.pickFiles(type: FileType.custom,
                  allowedExtensions: ['gguf']);
              if (picked.isEmpty) return;
              final file = picked.single;
              if (file.path == null) throw StateError('The selected file could not be read.');
              await ref.read(modelDownloadProvider.notifier).importModel(selected,
                  path: file.path!, pickedName: file.name);
              await _refreshDownloaded();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Local model imported and validated.')));
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Model import failed: $e')));
              }
            }
          },
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('Import downloaded GGUF'),
        ),
        Text('Select exactly ${selected.fileName}. Only this catalog Q4_K_M model is supported; other models, quantizations and incomplete files are rejected.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        Text(
          'Device acceleration',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const Text(
          'Transformer layers offloaded to the GPU. 99 requests all layers and uses more memory; '
          '0 uses CPU. Use CPU if conversion stalls or Android closes the app.',
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
              child: Text(
                '${settings.onDeviceGpuLayers}',
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _VoicePicker extends ConsumerWidget {
  final ConversionModeNotifier notifier;
  final ConversionModeSettings settings;
  const _VoicePicker({required this.notifier, required this.settings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                title: const Text('Kokoro (on-device neural, default)'),
                subtitle: const Text(
                  'Natural neural voice, fully offline. Voice data (~110 MB) downloads once, on first use.',
                ),
                value: 'kokoroOnnx',
              ),
              RadioListTile<String>(
                title: const Text('System voice'),
                subtitle: const Text(
                  'Instant, no download. Uses an installed offline English voice; download one in Android speech settings if needed.',
                ),
                value: 'stockTts',
              ),
            ],
          ),
        ),
        if (settings.isKokoroVoice) ...[
          KokoroModelControls(settings: settings, notifier: notifier),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: kKokoroVoices.contains(settings.kokoroVoice)
                ? settings.kokoroVoice
                : kKokoroVoices.first,
            decoration: const InputDecoration(
              labelText: 'Kokoro voice',
              helperText:
                  'Narrator: 11 presets (American and British). Emma, Isabella, George, Lewis and Sky need the small extra-voices download above. Novel characters use the choices below.',
              helperMaxLines: 5,
              border: OutlineInputBorder(),
            ),
            items: [
              for (final info in kKokoroVoiceCatalog)
                DropdownMenuItem(
                  value: info.name,
                  child: Text(
                    '${info.name} · ${info.isFemale ? 'Female' : 'Male'} · ${info.accent}'
                    '${info.bundled || (ref.watch(kokoroUsableVoicesProvider).asData?.value.contains(info.name) ?? false) ? '' : ' · needs voice download'}',
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) notifier.setKokoroVoice(v);
            },
          ),
          if (settings.contentMode == 'novel') ...[
            const SizedBox(height: 12),
            const _HelpText(
              'Automatic casting uses he/she evidence in the book, never names alone. Conflicting or missing evidence keeps the narrator. Override any named character below; voice casting does not establish a person’s gender.',
            ),
            if (settings.mode == ConversionModePref.onDevice)
              SwitchListTile(
                title: const Text('Analyze characters with the local model'),
                subtitle: const Text('Optional. Uses the selected downloaded GGUF and GPU setting to read book excerpts. No Wikipedia or API requests; unsupported traits stay unknown. It adds conversion time and memory use. Online research is skipped while this is on.'),
                value: settings.localCharacterResearch,
                onChanged: notifier.setLocalCharacterResearch,
              ),
            SwitchListTile(
              title: const Text('Research characters online (automatic)'),
              subtitle: Text(
                settings.mode == ConversionModePref.cloud
                    ? 'The server looks the book up on Wikipedia and asks its LLM for each character\'s age and temperament, so characters sound different. Only the title and character names are sent, never the book\'s text.'
                    : settings.onDeviceLlmUrl.trim().isEmpty ||
                          settings.onDeviceLlmApiKey.trim().isEmpty ||
                          settings.onDeviceLlmModel.trim().isEmpty
                    ? 'Runs automatically for every novel once an LLM URL, key and model are saved above: it looks the book up on Wikipedia and asks the LLM for each character\'s age and temperament. Only the title and character names are sent, never the book\'s text.'
                    : 'On. Each novel is looked up on Wikipedia and your LLM describes every character\'s age and temperament, so characters get different speed, pitch and voice. Only the title and character names are sent, never the book\'s text.',
              ),
              value: settings.researchCharacters,
              onChanged: settings.mode == ConversionModePref.onDevice && settings.localCharacterResearch ? null : notifier.setResearchCharacters,
            ),
            for (final male in [true, false]) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: ValueKey(
                  male ? 'male-character-voice' : 'female-character-voice',
                ),
                initialValue: male ? settings.maleVoice : settings.femaleVoice,
                decoration: InputDecoration(
                  labelText: male
                      ? 'Male character voice'
                      : 'Female character voice',
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final v
                      in male ? kKokoroAllMaleVoices : kKokoroAllFemaleVoices)
                    DropdownMenuItem(value: v, child: Text(v)),
                ],
                onChanged: (v) => notifier.setCharacterVoiceDefaults(
                  male: male ? v : null,
                  female: male ? null : v,
                ),
              ),
            ],
            const SizedBox(height: 12),
            _OverridesField(
              initialText: settings.characterVoices.entries
                  .map((e) => '${e.key}=${e.value}')
                  .join('\n'),
              onValid: (overrides) =>
                  notifier.setCharacterVoiceDefaults(overrides: overrides),
            ),
          ],
        ],
      ],
    );
  }
}

@visibleForTesting
Map<String, String>? parseVoiceOverrides(String value) {
  final result = <String, String>{};
  for (final line
      in value.split('\n').where((line) => line.trim().isNotEmpty)) {
    final parts = line.split('=');
    if (parts.length != 2 || parts[0].trim().isEmpty) return null;
    // The value is an optional voice preset plus optional trait words.
    final words = parts[1]
        .split(RegExp(r'[,\s]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final voices = words.where((w) => kKokoroVoices.contains(w)).toList();
    final unknown = words.where(
      (w) =>
          !kKokoroVoices.contains(w) && CharacterTraits.parseWords([w]) == null,
    );
    if (words.isEmpty || voices.length > 1 || unknown.isNotEmpty) return null;
    result[parts[0].trim()] = words.join(', ');
  }
  return result;
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
            Expanded(
              child: Text(
                'Server library',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Re-check connection',
              onPressed: state.checking
                  ? null
                  : () => ref.read(serverBooksProvider.notifier).check(),
            ),
          ],
        ),
        if (state.checking)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (state.connected == null)
          const Text('Not checked yet.')
        else if (state.connected == false)
          Row(
            children: [
              Icon(Icons.error_outline_rounded, color: scheme.error, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.error ?? 'Could not reach this server.',
                  style: TextStyle(color: scheme.error),
                ),
              ),
            ],
          )
        else ...[
          Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: Colors.green,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Connected — ${state.books.length} book${state.books.length == 1 ? '' : 's'} on the server',
                ),
              ),
            ],
          ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(state.error!, style: TextStyle(color: scheme.error)),
            ),
          const SizedBox(height: 8),
          for (final book in state.books) _ServerBookTile(book: book),
        ],
      ],
    );
  }
}

/// Admin-only shortcut to the Server administration console. Renders
/// nothing for non-admins, and nothing while IAM is off (unless the
/// account is the legacy admin) — non-admins never learn the screen
/// exists.
class _ServerAdminSection extends ConsumerWidget {
  const _ServerAdminSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(showAdminSectionProvider)) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          'Server administration',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Users, models, run pattern and queue — admins only.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('Server administration'),
            subtitle: const Text('Users, models, run pattern, queue'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ServerAdminScreen()),
            ),
          ),
        ),
      ],
    );
  }
}

class _ServerBookTile extends ConsumerWidget {
  final BookSummary book;
  const _ServerBookTile({required this.book});

  String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${book.sectionCount} sections · ${_formatSize(book.sizeBytes)}',
        ),
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
        content: Text(
          '"${book.title}" will be permanently removed from the server to free up space. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(serverBooksProvider.notifier).deleteBook(book.bookId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "${book.title}" from the server')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }
}

/// "Load models" and "Test connection" for an OpenAI-compatible endpoint
/// (OpenRouter, Groq, Gemini's OpenAI layer, ...). Works on whatever is typed
/// in the three fields, so it can be used before saving.
class _EndpointTools extends StatefulWidget {
  final TextEditingController urlController;
  final TextEditingController keyController;
  final TextEditingController modelController;
  const _EndpointTools({
    required this.urlController,
    required this.keyController,
    required this.modelController,
  });

  @override
  State<_EndpointTools> createState() => _EndpointToolsState();
}

class _EndpointToolsState extends State<_EndpointTools> {
  List<String> _models = const [];
  bool _busy = false;
  String? _message;
  bool _ok = false;

  LlmEndpoint get _endpoint => LlmEndpoint(
    baseUrl: widget.urlController.text,
    apiKey: widget.keyController.text,
  );

  Future<void> _run(Future<String> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final msg = await action();
      if (mounted) {
        setState(() {
          _ok = true;
          _message = msg;
        });
      }
    } on LlmEndpointException catch (e) {
      if (mounted) {
        setState(() {
          _ok = false;
          _message = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _ok = false;
          _message = 'Something went wrong: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens the guide; if the user picks a provider's URL there, fill it in.
  Future<void> _openKeyGuide() async {
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const LlmKeyGuideScreen()),
    );
    if (url != null && mounted) {
      widget.urlController.text = url;
      setState(() {
        _ok = true;
        _message = 'URL filled in. Paste your API key, then tap Load models.';
      });
    }
  }

  Future<void> _loadModels() => _run(() async {
    final found = await _endpoint.listModels();
    if (mounted) setState(() => _models = found);
    final free = found.where((m) => m.endsWith(':free')).length;
    return 'Found ${found.length} models${free > 0 ? ' ($free free)' : ''}. Pick one below.';
  });

  Future<void> _test() => _run(() async {
    var model = widget.modelController.text.trim();
    if (model.isEmpty) {
      throw LlmEndpointException(
        'Choose or type a model name first (tap Load models).',
      );
    }
    return _endpoint.test(model: model);
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _loadModels,
              icon: const Icon(Icons.list_alt_rounded, size: 18),
              label: const Text('Load models'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _test,
              icon: const Icon(Icons.network_check_rounded, size: 18),
              label: const Text('Test connection'),
            ),
            TextButton.icon(
              onPressed: _openKeyGuide,
              icon: const Icon(Icons.help_outline_rounded, size: 18),
              label: const Text('How to get a free API key'),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
        if (_models.isNotEmpty) ...[
          const SizedBox(height: 12),
          DropdownMenu<String>(
            expandedInsets: EdgeInsets.zero,
            enableFilter: true,
            requestFocusOnTap: true,
            label: const Text('Pick a model (type to search)'),
            dropdownMenuEntries: [
              for (final m in _models) DropdownMenuEntry(value: m, label: m),
            ],
            onSelected: (m) {
              if (m != null) widget.modelController.text = m;
            },
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                size: 18,
                color: _ok ? Colors.green : scheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _message!,
                  style: TextStyle(
                    color: _ok ? scheme.onSurface : scheme.error,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Free-text "Name=Voice / traits" lines. The error is computed from the text
/// currently in the box on every build, never remembered from an earlier
/// keystroke, so it can't go stale while typing on a real keyboard. Only
/// valid text is saved; invalid text keeps the last good saved value.
class _OverridesField extends StatefulWidget {
  final String initialText;
  final void Function(Map<String, String> overrides) onValid;
  const _OverridesField({required this.initialText, required this.onValid});

  @override
  State<_OverridesField> createState() => _OverridesFieldState();
}

class _OverridesFieldState extends State<_OverridesField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final invalid = parseVoiceOverrides(value.text) == null;
        return TextField(
          key: const ValueKey('character-voice-overrides'),
          controller: _controller,
          maxLines: 4,
          minLines: 3,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            labelText: 'Character voice overrides',
            hintText:
                'Alice=Sarah\nBob=Michael, elder, gruff\nTom=child cheerful',
            helperText:
                'One character per line: Name=Voice, Name=traits, or both. Names match the speaker in the book without regard to case, and "Hatter" also matches "Mad Hatter". Voices: Default, Bella, Nicole, Sarah, Adam, Michael. Traits: child, young, adult, elder; calm, cheerful, stern, gruff, gentle, energetic, mysterious; male, female.',
            helperMaxLines: 10,
            errorText: invalid
                ? 'Use Name=Voice and/or traits, e.g. Bob=Michael, elder, gruff. Not saved yet.'
                : null,
            errorMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
          onChanged: (text) {
            final overrides = parseVoiceOverrides(text);
            if (overrides != null) widget.onValid(overrides);
          },
        );
      },
    );
  }
}
