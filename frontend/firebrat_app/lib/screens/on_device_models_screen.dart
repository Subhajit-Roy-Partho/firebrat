import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import 'package:path_provider/path_provider.dart';
import '../state/on_device_conversion_providers.dart';

/// On-device models & voice settings: which local LLM to run (downloaded
/// as GGUF weights straight from Hugging Face), how many layers to push
/// to the GPU, and which narrator to use (platform TTS vs on-device
/// Kokoro neural voice). The easy-chunk LLM and the voice run fully
/// offline; hard chunks still go to the cloud LLM configured one screen
/// back, so both options stay available side by side.
class OnDeviceModelsScreen extends ConsumerStatefulWidget {
  const OnDeviceModelsScreen({super.key});

  @override
  ConsumerState<OnDeviceModelsScreen> createState() => _OnDeviceModelsScreenState();
}

class _OnDeviceModelsScreenState extends ConsumerState<OnDeviceModelsScreen> {
  String? _modelsDir;
  final Map<String, bool> _downloaded = {};
  String? _downloadingId;
  double? _downloadFraction;
  String _downloadStatus = '';

  @override
  void initState() {
    super.initState();
    _initDir();
  }

  Future<void> _initDir() async {
    final dir = '${(await getApplicationSupportDirectory()).path}/firebrat_models';
    if (!mounted) return;
    setState(() => _modelsDir = dir);
    await _refreshDownloaded();
  }

  /// Same path + tolerance rule as `ModelDownloader.ensureDownloaded`, so
  /// the badge here always agrees with what a conversion would do.
  Future<void> _refreshDownloaded() async {
    final dir = _modelsDir;
    if (dir == null) return;
    final result = <String, bool>{};
    for (final m in kOnDeviceLlmCatalog) {
      final f = File('$dir/${m.fileName}');
      result[m.id] = await f.exists() &&
          ((await f.length()) - m.approxSizeBytes).abs() < m.approxSizeBytes * 0.02;
    }
    if (mounted) setState(() => _downloaded.addAll(result));
  }

  Future<void> _download(OnDeviceLlmModel model) async {
    final dir = _modelsDir;
    if (dir == null || _downloadingId != null) return;
    setState(() {
      _downloadingId = model.id;
      _downloadFraction = 0;
      _downloadStatus = 'starting…';
    });
    try {
      await ModelDownloader().ensureDownloaded(
        model,
        dir,
        onProgress: (p, status) {
          if (mounted) {
            setState(() {
              _downloadFraction = p;
              _downloadStatus = status;
            });
          }
        },
      );
      await _refreshDownloaded();
    } catch (e) {
      if (mounted) setState(() => _downloadStatus = 'failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _downloadingId = null;
          _downloadFraction = null;
        });
      }
    }
  }

  static String _gb(int bytes) => '${(bytes / 1073741824).toStringAsFixed(1)} GB';

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(conversionModeProvider);
    final notifier = ref.read(conversionModeProvider.notifier);
    final selected = findOnDeviceLlmModel(settings.onDeviceLlmModelId);

    return Scaffold(
      appBar: AppBar(title: const Text('On-device models & voice')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Local LLM', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'Easy chunks run on this model, fully offline. '
            'Weights download straight from Hugging Face as quantized GGUF.',
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: selected.id,
            decoration: const InputDecoration(
              labelText: 'Model',
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
          const SizedBox(height: 8),
          Text(selected.description, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          _ModelDownloadRow(
            model: selected,
            downloaded: _downloaded[selected.id] ?? false,
            downloading: _downloadingId == selected.id,
            fraction: _downloadFraction,
            status: _downloadStatus,
            onDownload: () => _download(selected),
          ),
          const Divider(height: 32),
          Text('Hardware acceleration', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'Transformer layers offloaded to the GPU (llama.cpp). '
            '99 pushes everything that fits; 0 forces pure CPU if the '
            'GPU driver misbehaves.',
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
          const Divider(height: 32),
          Text('Narrator voice', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          RadioGroup<String>(
            groupValue: settings.voiceEngine,
            onChanged: (v) {
              if (v != null) notifier.setVoiceEngine(v);
            },
            child: Column(
              children: [
                RadioListTile<String>(
                  title: const Text('System voice'),
                  subtitle: const Text(
                    'Platform text-to-speech. Zero downloads, instant start.',
                  ),
                  value: 'stockTts',
                ),
                RadioListTile<String>(
                  title: const Text('Kokoro (on-device neural)'),
                  subtitle: const Text(
                    'Kokoro-82M runs fully offline via ONNX. Voice data '
                    'downloads on first use (~300 MB).',
                  ),
                  value: 'kokoroOnnx',
                ),
              ],
            ),
          ),
          if (settings.isKokoroVoice) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: kKokoroVoices.contains(settings.kokoroVoice)
                  ? settings.kokoroVoice
                  : kKokoroVoices.first,
              decoration: const InputDecoration(
                labelText: 'Kokoro voice',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final v in kKokoroVoices)
                  DropdownMenuItem(value: v, child: Text(v)),
              ],
              onChanged: (v) {
                if (v != null) notifier.setKokoroVoice(v);
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _ModelDownloadRow extends StatelessWidget {
  final OnDeviceLlmModel model;
  final bool downloaded;
  final bool downloading;
  final double? fraction;
  final String status;
  final VoidCallback onDownload;

  const _ModelDownloadRow({
    required this.model,
    required this.downloaded,
    required this.downloading,
    required this.fraction,
    required this.status,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    if (downloading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: fraction),
          const SizedBox(height: 4),
          Text(status, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
    }
    return Row(
      children: [
        if (downloaded)
          const Chip(
            avatar: Icon(Icons.check_circle_rounded, size: 18),
            label: Text('Downloaded'),
          )
        else
          FilledButton.icon(
            onPressed: onDownload,
            icon: const Icon(Icons.download_rounded),
            label: Text('Download ${_gbFor(model)}'),
          ),
      ],
    );
  }

  static String _gbFor(OnDeviceLlmModel m) =>
      '${(m.approxSizeBytes / 1073741824).toStringAsFixed(1)} GB';
}
