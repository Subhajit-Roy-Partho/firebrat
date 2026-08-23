import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/on_device_conversion_providers.dart';

/// The one choice this app needs from the user for "how do I convert a new
/// book": send it to a Firebrat server, or convert it on this device. Cloud
/// mode needs just the server's URL; on-device mode needs an
/// OpenAI-compatible LLM endpoint (url/key/model) for the chunks the
/// on-device model routes to the cloud — see `mobile-Backend/PROPOSAL.md` §5.
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
