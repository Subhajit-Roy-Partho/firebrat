import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart' hide KeepAliveHandle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
import '../services/app_network_gate.dart';
import '../services/device_probe.dart';
import '../services/download_task_handler.dart';
import '../state/on_device_conversion_providers.dart';
import 'model_choice_widgets.dart';

final _kokoroReady = FutureProvider<bool>((ref) => KokoroTtsEngine.isDownloaded());
final _modelPresent = FutureProvider.family<bool, String>((ref, id) async {
  final m = findTtsModel(id);
  return m.bundledWithBase || await KokoroAssets.isModelPresent(m);
});
final _extraVoicesPresent = FutureProvider<bool>((ref) => KokoroAssets.areExtraVoicesPresent());

/// Voices that can be used right now (bundled six + downloaded extras).
final kokoroUsableVoicesProvider = FutureProvider<Set<String>>((ref) async {
  return {
    for (final v in kKokoroVoiceCatalog)
      if (v.bundled) v.name,
    ...await KokoroAssets.availableExtraVoiceNames(),
  };
});

/// What the last narration really ran on (written by the engine).
final _lastRun = FutureProvider<Map<String, dynamic>?>((ref) async {
  try {
    final f = File('${await KokoroAssets.baseDir()}/last_run.json');
    if (!await f.exists()) return null;
    return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
});

class _XferState {
  final bool downloading;
  final double? fraction;
  final String message;
  final String? waiting;
  final bool ready;
  const _XferState({this.downloading = false, this.fraction, this.message = '', this.waiting, this.ready = false});
}

/// One transfer slot, used for the base pack, a model variant, or extra voices.
class _Xfer extends Notifier<_XferState> {
  @override
  _XferState build() => const _XferState();
  CancelToken? _cancel;

  void pause() => _cancel?.cancel('paused by user');

  Future<void> run(String title, int sizeBytes, Future<void> Function(CancelToken token, void Function(double?, String) progress) body,
      VoidCallback onDone) async {
    if (state.downloading) return;
    state = _XferState(downloading: true, message: 'Preparing $title...');
    KeepAliveHandle? keepAlive;
    var last = DateTime.fromMillisecondsSinceEpoch(0);
    final user = CancelToken();
    _cancel = user;
    try {
      keepAlive = await DownloadKeepAlive.acquire(title);
      await AppNetworkGate.instance.runGated<void>(
        sizeBytes,
        (gateToken) => body(gateToken, (p, status) {
          final now = DateTime.now();
          if (p != null && p < 1 && now.difference(last).inMilliseconds < 500) return;
          last = now;
          state = _XferState(downloading: true, fraction: p, message: status);
          DownloadKeepAlive.updateProgress('Downloading $title', status);
        }),
        userCancel: user,
        onWaiting: (label) => state = _XferState(
            downloading: true, fraction: state.fraction, message: label ?? state.message, waiting: label),
      );
      state = _XferState(ready: true, fraction: 1, message: '$title ready and verified');
      onDone();
    } catch (e) {
      final paused = user.isCancelled;
      state = _XferState(
          fraction: state.fraction,
          message: paused
              ? 'Paused. Tap download to resume; partial data is kept.'
              : '$title download failed. Check your connection and retry.');
    } finally {
      _cancel = null;
      await keepAlive?.release();
    }
  }
}

final _baseXfer = NotifierProvider<_Xfer, _XferState>(_Xfer.new);
final _modelXfer = NotifierProvider<_Xfer, _XferState>(_Xfer.new);
final _voicesXfer = NotifierProvider<_Xfer, _XferState>(_Xfer.new);

class _XferRow extends StatelessWidget {
  final _XferState state;
  final VoidCallback onPause;
  final bool canPause;
  const _XferRow({required this.state, required this.onPause, this.canPause = true});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      LinearProgressIndicator(value: state.waiting != null ? null : state.fraction?.clamp(0.0, 1.0)),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(
            child: Semantics(
                liveRegion: true,
                child: Text(
                    state.waiting != null
                        ? '${state.waiting} · partial download kept, resumes automatically'
                        : state.message,
                    style: Theme.of(context).textTheme.bodySmall))),
        if (canPause)
          TextButton.icon(onPressed: onPause, icon: const Icon(Icons.pause_rounded, size: 18), label: const Text('Pause')),
      ]),
    ]);
  }
}

String _mb(int bytes) => NetworkPolicy.formatSize(bytes);

/// Voice assets and execution settings are independent of the GGUF LLM.
class KokoroModelControls extends ConsumerWidget {
  final ConversionModeSettings settings;
  final ConversionModeNotifier notifier;
  const KokoroModelControls({super.key, required this.settings, required this.notifier});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = ref.watch(_baseXfer);
    final ready = base.ready || (ref.watch(_kokoroReady).asData?.value ?? false);
    final caps = ref.watch(deviceCapabilitiesProvider).asData?.value ?? DeviceCapabilities.unknown;
    final model = findTtsModel(settings.ttsModelId);
    final modelPresent = ref.watch(_modelPresent(model.id)).asData?.value ?? model.bundledWithBase;
    final modelXfer = ref.watch(_modelXfer);
    final voicesPresent = ref.watch(_extraVoicesPresent).asData?.value ?? false;
    final voicesXfer = ref.watch(_voicesXfer);
    final last = ref.watch(_lastRun).asData?.value;
    final pref = AcceleratorPreference.parse(settings.kokoroAcceleration);
    final plan = planAccelerators(preference: pref, device: caps, model: model);
    final fit = assessTts(model, caps);
    final threads = [1, 2, 4].contains(settings.kokoroCpuThreads) ? settings.kokoroCpuThreads : 2;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Kokoro model & voices', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      // 1. Base pack (default int8 model, six voices, espeak data).
      if (base.downloading)
        // The pinned flutter_kokoro_tts downloader cannot be paused mid-file; it only waits before starting.
        _XferRow(state: base, canPause: false, onPause: () {})
      else if (ready)
        const Chip(avatar: Icon(Icons.check_circle_outline, size: 18), label: Text('Kokoro & six voices downloaded'))
      else ...[
        FilledButton.icon(
          onPressed: () => ref.read(_baseXfer.notifier).run(
                'Kokoro voice models',
                110 * 1024 * 1024,
                (token, progress) => KokoroTtsEngine.downloadModels(onProgress: progress),
                () => ref.invalidate(_kokoroReady),
              ),
          icon: const Icon(Icons.download_outlined),
          label: const Text('Download Kokoro & voices (~110 MB)'),
        ),
        if (base.message.isNotEmpty) Text(base.message),
      ],
      const SizedBox(height: 12),
      // 2. Model variant.
      DropdownButtonFormField<String>(
        key: ValueKey('tts-model-${model.id}'),
        initialValue: model.id,
        isExpanded: true,
        decoration: const InputDecoration(
            labelText: 'Voice model', helperText: 'The default is the verified, lightest choice.', border: OutlineInputBorder()),
        items: [
          for (final m in kOnDeviceTtsCatalog)
            DropdownMenuItem(
              value: m.id,
              child: Text('${m.tier.label} · ${m.displayName} · ${_mb(m.approxSizeBytes)}', overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) {
          if (v != null) notifier.setTtsModel(v);
        },
      ),
      const SizedBox(height: 4),
      Text(
        '${model.description} Licence: ${model.license}. ${model.verifiedOnDevice ? 'Verified on a phone.' : 'Not yet measured on a physical phone.'}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (fit.warning != null) ...[
        const SizedBox(height: 8),
        NoticeCard(icon: Icons.memory_rounded, text: fit.warning!, severe: fit.fit == ModelFit.tooLarge),
      ],
      const SizedBox(height: 8),
      if (!model.bundledWithBase) ...[
        if (modelXfer.downloading)
          _XferRow(state: modelXfer, onPause: () => ref.read(_modelXfer.notifier).pause())
        else if (modelPresent || modelXfer.ready)
          const Chip(avatar: Icon(Icons.check_circle_outline, size: 18), label: Text('Model downloaded'))
        else ...[
          FilledButton.tonalIcon(
            onPressed: () => ref.read(_modelXfer.notifier).run(
                  model.displayName,
                  model.approxSizeBytes,
                  (token, progress) => KokoroAssets.downloadModel(model,
                      cancelToken: token, onBytes: (r, t) => progress(t == null || t == 0 ? null : r / t, 'downloading ${_mb(r)}${t == null ? '' : ' / ${_mb(t)}'}')),
                  () => ref.invalidate(_modelPresent(model.id)),
                ),
            icon: const Icon(Icons.download_outlined),
            label: Text('Download ${model.displayName} (${_mb(model.approxSizeBytes)})'),
          ),
          Text('Until it is downloaded the default int8 model is used.', style: Theme.of(context).textTheme.bodySmall),
          if (modelXfer.message.isNotEmpty) Text(modelXfer.message),
        ],
        const SizedBox(height: 8),
      ],
      // 3. Extra voices.
      if (voicesXfer.downloading)
        _XferRow(state: voicesXfer, onPause: () => ref.read(_voicesXfer.notifier).pause())
      else if (voicesPresent || voicesXfer.ready)
        const Chip(avatar: Icon(Icons.check_circle_outline, size: 18), label: Text('Extra voices downloaded (Sky, Emma, Isabella, George, Lewis)'))
      else ...[
        OutlinedButton.icon(
          onPressed: ready
              ? () => ref.read(_voicesXfer.notifier).run(
                    'Extra Kokoro voices',
                    kKokoroExtraVoices.length * 524288,
                    (token, progress) => KokoroAssets.downloadExtraVoices(cancelToken: token, onProgress: progress),
                    () {
                      ref.invalidate(_extraVoicesPresent);
                      ref.invalidate(kokoroUsableVoicesProvider);
                    },
                  )
              : null,
          icon: const Icon(Icons.record_voice_over_outlined),
          label: const Text('Download 5 extra voices (~2.5 MB)'),
        ),
        Text('Adds British voices Emma, Isabella, George, Lewis and American Sky.', style: Theme.of(context).textTheme.bodySmall),
        if (voicesXfer.message.isNotEmpty) Text(voicesXfer.message),
      ],
      const SizedBox(height: 8),
      const Align(alignment: Alignment.centerLeft, child: NetworkStatusChip()),
      const SizedBox(height: 12),
      // 4. Accelerator.
      DropdownButtonFormField<String>(
        key: ValueKey('kokoro-acceleration-${pref.storageValue}'),
        initialValue: pref.storageValue,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Speech accelerator', border: OutlineInputBorder()),
        items: [
          for (final p in AcceleratorPreference.values)
            DropdownMenuItem(
              value: p.storageValue,
              child: Text(switch (p) {
                AcceleratorPreference.auto => 'Auto (recommended)',
                AcceleratorPreference.gpuNpu => 'GPU / NPU (experimental)',
                AcceleratorPreference.cpu => 'CPU',
              }),
            ),
        ],
        onChanged: (v) {
          if (v != null) notifier.setKokoroAcceleration(v);
        },
      ),
      const SizedBox(height: 8),
      Text(
        'This phone could use: ${caps.ttsBackends.map((b) => b.label).join(', ')}. '
        'With the current settings it will try: ${plan.map((b) => b.label).join(' then ')}. '
        'GPU / NPU uses Android NNAPI; the driver decides whether the GPU, NPU or CPU runs each operation, '
        'and Kokoro may gain little or run slower. If it fails it falls back to CPU automatically. '
        'The GPU-layers slider above only controls the language model.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      Semantics(
        liveRegion: true,
        child: Text(
          last == null
              ? 'Running on: shown after the first narration.'
              : 'Running on: ${last['status']} (last run${last['realtime_factor'] != null ? ', ${last['realtime_factor']}x real time' : ''}). '
                  '${((last['notes'] as List?) ?? const []).join(' ')}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        key: ValueKey('kokoro-threads-$threads'),
        initialValue: threads,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Speech CPU budget', border: OutlineInputBorder()),
        items: const [
          DropdownMenuItem(value: 1, child: Text('1 thread · lighter phone load')),
          DropdownMenuItem(value: 2, child: Text('2 threads · balanced')),
          DropdownMenuItem(value: 4, child: Text('4 threads · more CPU use')),
        ],
        onChanged: (v) {
          if (v != null) notifier.setKokoroCpuThreads(v);
        },
      ),
      const SizedBox(height: 8),
      const Text('Changes apply to the next conversion or resume. Two threads leave more capacity for the phone; fewer threads can make narration slower.'),
      const SizedBox(height: 16),
    ]);
  }
}
