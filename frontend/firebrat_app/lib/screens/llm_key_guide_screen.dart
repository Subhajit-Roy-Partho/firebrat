import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const kOnlineLlmGuideUrl = 'https://subhajit-roy-partho.github.io/firebrat/documentation/guide.html#free-llm';

class _Provider {
  final String name;
  final String badge;
  final String url; // OpenAI-compatible base URL
  final String site;
  final String siteLabel;
  final List<String> steps;
  final String note;
  const _Provider(this.name, this.badge, this.url, this.site, this.siteLabel, this.steps, this.note);
}

const _providers = <_Provider>[
  _Provider(
    'OpenRouter',
    'Recommended',
    'https://openrouter.ai/api/v1',
    'https://openrouter.ai/keys',
    'Open openrouter.ai/keys',
    [
      'Sign up for a free account at openrouter.ai (an email or Google login is enough).',
      'Open Keys, tap "Create key", give it any name, and copy it. It is shown only once.',
      'Back in Firebrat, paste it into "API key" and tap "Load models".',
      'Choose a model whose name ends in ":free" (type "free" in the search box), then tap "Test connection".',
    ],
    'Free models are limited to 20 requests a minute, and 50 a day until you have bought at least 10 credits (then 1,000 a day). The free list changes often, so use Load models rather than copying a name from the web.',
  ),
  _Provider(
    'Groq',
    'Fast',
    'https://api.groq.com/openai/v1',
    'https://console.groq.com/keys',
    'Open console.groq.com/keys',
    [
      'Sign up at console.groq.com.',
      'Open API Keys, tap "Create API Key", and copy it.',
      'Paste it into "API key", tap "Load models", and pick a model.',
    ],
    'Groq has a free tier with its own rate limits; check their pricing page for the current numbers.',
  ),
  _Provider(
    'Google AI Studio (Gemini)',
    'Free tier',
    'https://generativelanguage.googleapis.com/v1beta/openai/',
    'https://aistudio.google.com/apikey',
    'Open aistudio.google.com',
    [
      'Sign in at aistudio.google.com with a Google account.',
      'Choose "Get API key", then "Create API key", and copy it.',
      'Paste it into "API key", tap "Load models", and pick a Gemini model.',
    ],
    'Google offers a free tier with rate limits; check their pricing page for the current limits.',
  ),
];

Future<void> _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

/// Explains how to get an LLM URL and key from free providers. Pops with a
/// provider's URL when the user taps "Use this URL", so the settings screen can
/// fill the field in.
class LlmKeyGuideScreen extends StatelessWidget {
  const LlmKeyGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Get a free API key')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text('An API key lets Firebrat use a cloud language model, which is much faster than your phone and needs no model download. '
              'Several services give out free keys. They all work the same way: a URL, a key, and a model name.',
              style: theme.textTheme.bodyLarge),
          const SizedBox(height: 12),
          Card(
            color: theme.colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.lock_outline_rounded, color: theme.colorScheme.onTertiaryContainer),
                    const SizedBox(width: 8),
                    Text('What gets sent', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onTertiaryContainer)),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                    'Character research sends only the book title and character names. '
                    '"Use the cloud LLM for every passage" and the cloud helper send book text to the provider you pick, and free providers may log prompts. '
                    'Keep private books on the on-device model.',
                    style: TextStyle(color: theme.colorScheme.onTertiaryContainer),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final p in _providers) _ProviderCard(provider: p),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _open(kOnlineLlmGuideUrl),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('Open the full guide online'),
          ),
        ],
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final _Provider provider;
  const _ProviderCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(provider.name, style: theme.textTheme.titleLarge)),
                Chip(label: Text(provider.badge), visualDensity: VisualDensity.compact),
              ],
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < provider.steps.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(radius: 11, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                    const SizedBox(width: 10),
                    Expanded(child: Text(provider.steps[i])),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text('URL to use', style: theme.textTheme.labelLarge),
            SelectableText(provider.url, style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace')),
            const SizedBox(height: 8),
            Text(provider.note, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => _open(provider.site),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(provider.siteLabel),
                ),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop(provider.url),
                  icon: const Icon(Icons.input_rounded, size: 18),
                  label: const Text('Use this URL'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
