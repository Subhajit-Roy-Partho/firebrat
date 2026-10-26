import 'package:flutter/material.dart' hide KeepAliveHandle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import '../services/download_task_handler.dart';
import '../state/on_device_conversion_providers.dart';

final _kokoroReady = FutureProvider<bool>((ref) => KokoroTtsEngine.isDownloaded());
final _kokoroProviders = FutureProvider<List<String>>((ref) => KokoroTtsEngine.availableAcceleration());

class _VoiceDownloadState {
  final bool downloading;
  final bool ready;
  final double? fraction;
  final String message;
  const _VoiceDownloadState({this.downloading = false, this.ready = false,
    this.fraction, this.message = ''});
}

class _VoiceDownload extends Notifier<_VoiceDownloadState> {
  @override
  _VoiceDownloadState build() => const _VoiceDownloadState();

  Future<void> start() async {
    if (state.downloading) return;
    state = const _VoiceDownloadState(downloading: true, message: 'Preparing Kokoro…');
    KeepAliveHandle? keepAlive;
    var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      keepAlive = await DownloadKeepAlive.acquire('Kokoro voice models');
      await KokoroTtsEngine.downloadModels(onProgress: (p, status) {
        final now = DateTime.now();
        if (p != null && p < 1 && now.difference(lastUpdate).inMilliseconds < 500) return;
        lastUpdate = now;
        state = _VoiceDownloadState(downloading: true,
          fraction: p, message: status);
        DownloadKeepAlive.updateProgress('Downloading Kokoro voices', status);
      });
      state = const _VoiceDownloadState(ready: true, fraction: 1,
        message: 'Kokoro and all six voice presets verified');
      ref.invalidate(_kokoroReady);
    } catch (_) {
      state = const _VoiceDownloadState(message: 'Kokoro download failed. Check your connection and retry.');
    } finally {
      await keepAlive?.release();
    }
  }
}

final _voiceDownload = NotifierProvider<_VoiceDownload, _VoiceDownloadState>(_VoiceDownload.new);

/// Voice assets and execution settings are independent of the GGUF LLM.
class KokoroModelControls extends ConsumerWidget {
  final ConversionModeSettings settings;
  final ConversionModeNotifier notifier;
  const KokoroModelControls({super.key, required this.settings, required this.notifier});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final download = ref.watch(_voiceDownload);
    final ready = download.ready || (ref.watch(_kokoroReady).asData?.value ?? false);
    final providers = ref.watch(_kokoroProviders).asData?.value ?? const ['cpu'];
    final nnapi = providers.contains('nnapi');
    final selected = nnapi && settings.kokoroAcceleration == 'nnapi' ? 'nnapi' : 'cpu';
    final threads = [1, 2, 4].contains(settings.kokoroCpuThreads) ? settings.kokoroCpuThreads : 2;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Kokoro model & voices', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      if (download.downloading) ...[
        LinearProgressIndicator(value: download.fraction?.clamp(0.0, 1.0)),
        const SizedBox(height: 8),
        Text(download.message),
      ] else if (ready)
        const Chip(avatar: Icon(Icons.check_circle_outline, size: 18),
          label: Text('Kokoro & voices downloaded'))
      else ...[
        FilledButton.icon(onPressed: () => ref.read(_voiceDownload.notifier).start(),
          icon: const Icon(Icons.download_outlined),
          label: const Text('Download Kokoro & voices (~110 MB)')),
        if (download.message.isNotEmpty) Text(download.message),
      ],
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        key: ValueKey('kokoro-acceleration-$selected'),
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Speech acceleration', border: OutlineInputBorder()),
        items: [const DropdownMenuItem(value: 'cpu', child: Text('CPU (recommended)')),
          if (nnapi) const DropdownMenuItem(value: 'nnapi', child: Text('NNAPI (experimental)'))],
        onChanged: (v) { if (v != null) notifier.setKokoroAcceleration(v); },
      ),
      const SizedBox(height: 8),
      Text(nnapi
        ? 'NNAPI may use the GPU, NPU or CPU depending on the Android driver. Unsupported operations use CPU; performance varies. If it is slower, choose CPU.'
        : 'This runtime exposes CPU narration. The GPU layer slider above only controls the language model.'),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        key: ValueKey('kokoro-threads-$threads'),
        initialValue: threads,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Speech CPU budget', border: OutlineInputBorder()),
        items: const [DropdownMenuItem(value: 1, child: Text('1 thread · lighter phone load')),
          DropdownMenuItem(value: 2, child: Text('2 threads · balanced')),
          DropdownMenuItem(value: 4, child: Text('4 threads · more CPU use'))],
        onChanged: (v) { if (v != null) notifier.setKokoroCpuThreads(v); },
      ),
      const SizedBox(height: 8),
      const Text('Changes apply to the next conversion or resume. Two threads leave more capacity for the phone; fewer threads can make narration slower.'),
      const SizedBox(height: 16),
    ]);
  }
}
