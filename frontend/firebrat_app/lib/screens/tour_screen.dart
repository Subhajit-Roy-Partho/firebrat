import 'package:flutter/material.dart';
import '../state/tour_providers.dart';

/// One "where is it / what does it do" line on a tour page.
class _TourItem {
  const _TourItem(this.icon, this.label, this.detail);
  final IconData icon;
  final String label;
  final String detail;
}

class _TourPage {
  const _TourPage({
    required this.icon,
    required this.title,
    required this.summary,
    this.items = const [],
  });
  final IconData icon;
  final String title;
  final String summary;
  final List<_TourItem> items;
}

const _pages = <_TourPage>[
  _TourPage(
    icon: Icons.headphones_rounded,
    title: 'Welcome to Firebrat',
    summary: 'Firebrat turns technical PDFs into narrated books: you listen '
        'while the text highlights and figures appear in sync. This short '
        'guide shows where everything is. You can reopen it any time from '
        'the menu.',
  ),
  _TourPage(
    icon: Icons.library_books_rounded,
    title: 'Your library',
    summary: 'The home screen lists every book on your device. Tap a book to '
        'open it. Pull down to refresh.',
    items: [
      _TourItem(Icons.menu_rounded, 'Menu (top left)',
          'Opens the side drawer: conversions, settings, sync, sign in/out, help.'),
      _TourItem(Icons.grid_view_rounded, 'Layout',
          'Switch between list, small cards and large cards.'),
      _TourItem(Icons.brightness_auto_rounded, 'Theme',
          'Match your phone, or force light or dark.'),
    ],
  ),
  _TourPage(
    icon: Icons.file_open_rounded,
    title: 'Adding books',
    summary: 'A book arrives as a finished package (.tar.gz or .zip) that '
        'Firebrat has already converted, or one you convert yourself.',
    items: [
      _TourItem(Icons.file_open_rounded, 'Import (top right)',
          'Pick a converted book file from your phone. A spinner shows progress.'),
      _TourItem(Icons.cloud_upload_rounded, 'Conversions (top right)',
          'Send a PDF to be converted and follow each job: queued, converting, done or failed. Finished books download into your library.'),
      _TourItem(Icons.memory_rounded, 'On-device or cloud',
          'Convert on your phone with a local model, or on a server if you sign in. Choose in Conversion settings.'),
    ],
  ),
  _TourPage(
    icon: Icons.chrome_reader_mode_rounded,
    title: 'Reading a book',
    summary: 'Books are split into sections. Swipe through the text, with '
        'formulas and figures shown inline.',
    items: [
      _TourItem(Icons.chevron_right_rounded, 'Section bar',
          'Previous and next section, plus "Section 3 of 12" so you know where you are.'),
      _TourItem(Icons.text_fields_rounded, 'Text size',
          'Make the text larger or smaller.'),
      _TourItem(Icons.fullscreen_rounded, 'Focus mode',
          'Hides distractions for just the text.'),
      _TourItem(Icons.picture_as_pdf_outlined, 'Source PDF',
          'Open the original page for any figure or table (when the book includes it).'),
    ],
  ),
  _TourPage(
    icon: Icons.play_circle_rounded,
    title: 'Listening',
    summary: 'The playback bar at the bottom reads the book aloud and '
        'highlights the sentence being spoken. Audio keeps playing with the '
        'screen off and from the notification.',
    items: [
      _TourItem(Icons.play_arrow_rounded, 'Play, pause, stop',
          'Start narration from where you are.'),
      _TourItem(Icons.skip_next_rounded, 'Previous / next segment',
          'Jump a sentence back or forward.'),
      _TourItem(Icons.speed_rounded, 'Speed chip (e.g. 1.0x)',
          'Tap to change narration speed.'),
      _TourItem(Icons.play_circle_outline, 'Autoplay chip',
          'Auto continues into the next section after a short delay you choose; Manual stops at the end of each section.'),
    ],
  ),
  _TourPage(
    icon: Icons.tune_rounded,
    title: 'Conversion modes',
    summary: 'Open Menu > Conversion settings and pick one of three modes '
        'under "How do you want to use Firebrat?". You can switch any time.',
    items: [
      _TourItem(Icons.offline_pin_outlined, 'Offline',
          'Read and listen to books you imported. No server, account or model needed, and nothing new is converted.'),
      _TourItem(Icons.cloud_outlined, 'Server',
          'Fastest. Datacenter GPUs convert your PDF, so the server must be online and you need to sign in. Enter the server URL, and pick LLM helper (default) or Native GPU as the engine.'),
      _TourItem(Icons.phone_android_outlined, 'On-device',
          'Private. Your phone does the conversion with a local model, so it is slower and uses battery, memory and storage. Needs a one-time model and voice download, then no account or server.'),
      _TourItem(Icons.menu_book_rounded, 'Book type',
          'Illustrated / technical keeps figures and formulas. Novel / characters gives each named speaker their own voice.'),
    ],
  ),
  _TourPage(
    icon: Icons.memory_rounded,
    title: 'Picking an on-device model',
    summary: 'Bigger models read hard passages better but need more memory '
        'and time. Listed from lightest to heaviest on your phone '
        '(approximate RAM while converting). If Android closes the app or '
        'conversion stalls, step down a size.',
    items: [
      _TourItem(Icons.battery_full_rounded, 'Qwen3 0.6B  ·  ~1 GB',
          'Lightest and fastest. Safe on 4-6 GB phones.'),
      _TourItem(Icons.battery_full_rounded, 'Gemma 3 1B  ·  ~1.5 GB',
          'Compact, text-only. Good for low-memory phones.'),
      _TourItem(Icons.battery_6_bar_rounded, 'SmolLM2 1.7B  ·  ~1.7 GB',
          'Small general model, fine on 6 GB+.'),
      _TourItem(Icons.battery_5_bar_rounded, 'Qwen3 1.7B  ·  ~2 GB (default)',
          'Balanced choice for 6-8 GB phones. Start here.'),
      _TourItem(Icons.battery_4_bar_rounded, 'Llama 3.2 3B  ·  ~3 GB',
          'Better quality for 8 GB phones.'),
      _TourItem(Icons.battery_2_bar_rounded, 'Qwen3 4B, Gemma 3 4B, Phi-4 Mini  ·  ~3.8 GB',
          'Highest quality and heaviest. May run out of memory on 8 GB phones, especially with GPU offload. Phi-4 Mini is good at math-heavy text.'),
      _TourItem(Icons.speed_rounded, 'Device acceleration slider',
          'Moves model layers to the GPU. Higher is faster but uses more memory; 0 uses the CPU only. Lower it if conversion stalls.'),
      _TourItem(Icons.cloud_sync_outlined, 'Allow cloud helper',
          'Optional. Sends only hard passages (equations, figures, tables) to your own LLM endpoint. Off keeps everything on the phone.'),
    ],
  ),
  _TourPage(
    icon: Icons.settings_outlined,
    title: 'Settings and sync',
    summary: 'Everything else lives in the menu drawer.',
    items: [
      _TourItem(Icons.settings_outlined, 'Conversion settings',
          'Models, GPU use, narrator voice and cloud server, all on one page.'),
      _TourItem(Icons.sync_rounded, 'Sync & backup',
          'Keeps your reading position in Firebase and backs books up to your Drive.'),
      _TourItem(Icons.login_rounded, 'Sign in / Guest',
          'Guests can read, import and convert on-device with no account. Sign in for cloud conversion and sync.'),
      _TourItem(Icons.privacy_tip_outlined, 'Privacy & support',
          'Help, bug reports and account deletion.'),
    ],
  ),
];

/// Full-screen first-run walkthrough. Returns when finished or skipped;
/// either way the "seen" flag is stored so it won't reopen on its own.
class TourScreen extends StatefulWidget {
  const TourScreen({super.key});

  @override
  State<TourScreen> createState() => _TourScreenState();
}

class _TourScreenState extends State<TourScreen> {
  final _controller = PageController();
  int _index = 0;

  bool get _isLast => _index == _pages.length - 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await TourStore.markSeen();
    if (mounted) Navigator.of(context).pop();
  }

  void _go(int delta) => _controller.animateToPage(
        _index + delta,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      // Back button counts as skip, so it is remembered too.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _finish,
                  child: Text(_isLast ? 'Close' : 'Skip'),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _pages.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => _PageView(page: _pages[i]),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _pages.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _index ? 18 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _index ? scheme.primary : scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                // Wrap, not Row: at large text scales the two buttons stack
                // instead of overflowing a narrow screen.
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 8,
                  children: [
                    if (_index == 0)
                      const SizedBox.shrink()
                    else
                      TextButton(
                        onPressed: () => _go(-1),
                        child: const Text('Back'),
                      ),
                    FilledButton(
                      onPressed: _isLast ? _finish : () => _go(1),
                      child: Text(_isLast ? 'Get started' : 'Next'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PageView extends StatelessWidget {
  const _PageView({required this.page});
  final _TourPage page;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      children: [
        Center(
          child: CircleAvatar(
            radius: 36,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Icon(page.icon,
                size: 36, color: theme.colorScheme.onPrimaryContainer),
          ),
        ),
        const SizedBox(height: 20),
        Text(page.title,
            textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text(page.summary,
            textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
        const SizedBox(height: 16),
        for (final item in page.items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(item.icon, color: theme.colorScheme.primary),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.label, style: theme.textTheme.titleSmall),
                      Text(item.detail, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
