import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/server_admin.dart';
import '../services/api_client.dart';
import '../state/library_providers.dart' show apiClientProvider;
import '../state/server_admin_providers.dart';

/// Server administration (admin role only; hidden otherwise). Four
/// numbered sections mirroring the Conversion settings style:
/// 1 · Users — invite by email + role, change role, disable, remove.
/// 2 · Models — the three server selects with VRAM hints and
/// "weights not downloaded" warnings.
/// 3 · Run pattern — batched/sequential, queue order, pause, quiet hours.
/// 4 · Queue — live scheduler status, pause/resume, cancel, move to top.
///
/// Every choice is picked from the server-defined catalog
/// (GET /admin/settings options); parsing stays defensive so an older
/// or newer server shape renders instead of red-screening.
class ServerAdminScreen extends ConsumerWidget {
  const ServerAdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server administration')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _SectionTitle('1 · Users'),
          _HelpText(
            'Admins do everything; users upload and manage their own books; '
            'viewers can only listen. Invites claim automatically when the '
            'verified email first signs in.',
          ),
          SizedBox(height: 8),
          _UsersSection(),
          SizedBox(height: 24),
          _SectionTitle('2 · Models'),
          _HelpText(
            'Picked from the server catalog — free text is never sent. '
            'A warning means the weights are not in the server cache yet.',
          ),
          SizedBox(height: 8),
          _ModelsSection(),
          SizedBox(height: 24),
          _SectionTitle('3 · Run pattern'),
          _HelpText(
            'Batched casts every queued book together, then narrates; '
            'sequential finishes one book end to end. Hot-reloads on the '
            'server — no restart needed.',
          ),
          SizedBox(height: 8),
          _RunPatternSection(),
          SizedBox(height: 24),
          _SectionTitle('4 · Queue'),
          SizedBox(height: 8),
          _QueueSection(),
          SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ---- 1 · Users ----

/// Invite row + user list. Mutations invalidate [adminUsersProvider] so
/// the list refreshes; server errors (last-admin protection, …) surface
/// as snackbars with the server's own message.
class _UsersSection extends ConsumerStatefulWidget {
  const _UsersSection();

  @override
  ConsumerState<_UsersSection> createState() => _UsersSectionState();
}

class _UsersSectionState extends ConsumerState<_UsersSection> {
  final _email = TextEditingController();
  String _role = 'user';
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(ApiClient api) action) async {
    setState(() => _busy = true);
    try {
      await action(ref.read(apiClientProvider));
      ref.invalidate(adminUsersProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ApiClient.friendlyAdminError(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(adminUsersProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('invite-email'),
          controller: _email,
          decoration: const InputDecoration(
            labelText: 'Invite by email',
            hintText: 'reader@example.com',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.emailAddress,
          enabled: !_busy,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final r in const ['admin', 'user', 'viewer'])
              ChoiceChip(
                label: Text(r),
                selected: _role == r,
                onSelected: _busy ? null : (_) => setState(() => _role = r),
              ),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () {
                      final email = _email.text.trim();
                      if (email.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Enter an email to invite.'),
                          ),
                        );
                        return;
                      }
                      _run((api) => api.inviteUser(email: email, role: _role));
                    },
              icon: const Icon(Icons.person_add_outlined, size: 18),
              label: const Text('Invite'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        users.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text(
            'Could not load users: ${ApiClient.friendlyAdminError(e)}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          data: (list) {
            if (list.isEmpty) {
              return const Text('No accounts yet — invites appear here.');
            }
            return Column(
              children: [
                for (final u in list)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: Icon(
                        u.role == 'admin'
                            ? Icons.shield_rounded
                            : !u.isActive
                            ? Icons.person_off_outlined
                            : Icons.person_outline_rounded,
                      ),
                      title: Text(
                        u.email.isNotEmpty
                            ? u.email
                            : (u.name.isNotEmpty ? u.name : u.id),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${u.role}${u.claimed ? '' : ' · invited, not signed in yet'}'
                        '${u.isActive ? '' : ' · disabled'}',
                      ),
                      trailing: PopupMenuButton<String>(
                        enabled: !_busy,
                        tooltip: 'Change role, disable, or remove',
                        onSelected: (action) => _onUserAction(u, action),
                        itemBuilder: (context) => [
                          for (final r in const ['admin', 'user', 'viewer'])
                            if (r != u.role)
                              PopupMenuItem(
                                value: 'role:$r',
                                child: Text('Make $r'),
                              ),
                          PopupMenuItem(
                            value: u.isActive ? 'disable' : 'enable',
                            child: Text(u.isActive ? 'Disable' : 'Enable'),
                          ),
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('Remove'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Future<void> _onUserAction(AdminUser user, String action) async {
    if (action.startsWith('role:')) {
      await _run((api) => api.updateUser(user.id, role: action.substring(5)));
    } else if (action == 'disable' || action == 'enable') {
      await _run(
        (api) => api.updateUser(
          user.id,
          status: action == 'disable' ? 'disabled' : 'active',
        ),
      );
    } else if (action == 'remove') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove this account?'),
          content: Text(
            '"${user.email.isNotEmpty ? user.email : user.id}" loses server access. Their books stay.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await _run((api) => api.removeUser(user.id));
      }
    }
  }
}

// ---- 2 · Models + 3 · Run pattern ----

/// One catalog entry: an id the server accepts plus display hints.
class _Option {
  final String id;
  final String? label;
  final double? vramGb;
  final bool? available;
  final String? description;
  const _Option({
    required this.id,
    this.label,
    this.vramGb,
    this.available,
    this.description,
  });
}

Widget _loadError(
  BuildContext context,
  String what,
  Object e,
  VoidCallback retry,
) {
  return Row(
    children: [
      Expanded(
        child: Text(
          'Could not load $what: ${ApiClient.friendlyAdminError(e)}',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
      TextButton(onPressed: retry, child: const Text('Retry')),
    ],
  );
}

class _ModelsSection extends ConsumerStatefulWidget {
  const _ModelsSection();

  @override
  ConsumerState<_ModelsSection> createState() => _ModelsSectionState();
}

class _ModelsSectionState extends ConsumerState<_ModelsSection> {
  bool _seeded = false;
  bool _saving = false;
  String? _llmModel;
  String? _quantization;
  String? _ttsEngine;

  void _seedOnce(Map<String, dynamic> values) {
    if (_seeded) return;
    _seeded = true;
    final llm = _map(values['llm']);
    final tts = _map(values['tts']);
    _llmModel = llm['model']?.toString();
    _quantization = llm['quantization']?.toString();
    _ttsEngine = tts['engine']?.toString();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).putAdminSettings({
        'llm': {
          if (_llmModel != null) 'model': _llmModel,
          if (_quantization != null) 'quantization': _quantization,
        },
        'tts': {if (_ttsEngine != null) 'engine': _ttsEngine},
      });
      ref.invalidate(adminSettingsProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Models saved.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ApiClient.friendlyAdminError(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(adminSettingsProvider);
    return settings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _loadError(
        context,
        'server settings',
        e,
        () => ref.invalidate(adminSettingsProvider),
      ),
      data: (s) {
        _seedOnce(s.values);
        final llmOpts = _optionsFrom(
          _map(s.options['llm'])['models'],
          s.availability['llm'],
          _llmModel,
        );
        final quantOpts = _optionsFrom(
          _map(s.options['llm'])['quantizations'],
          null,
          _quantization,
        );
        final ttsOpts = _optionsFrom(
          _map(s.options['tts'])['engines'],
          s.availability['tts'],
          _ttsEngine,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CatalogDropdown(
              label: 'LLM',
              value: _llmModel,
              options: llmOpts,
              onChanged: (v) => setState(() => _llmModel = v),
            ),
            const SizedBox(height: 12),
            _CatalogDropdown(
              label: 'Quantization',
              value: _quantization,
              options: quantOpts,
              onChanged: (v) => setState(() => _quantization = v),
            ),
            const SizedBox(height: 12),
            _CatalogDropdown(
              label: 'TTS engine',
              value: _ttsEngine,
              options: ttsOpts,
              onChanged: (v) => setState(() => _ttsEngine = v),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('Save models'),
            ),
          ],
        );
      },
    );
  }
}

class _RunPatternSection extends ConsumerStatefulWidget {
  const _RunPatternSection();

  @override
  ConsumerState<_RunPatternSection> createState() => _RunPatternSectionState();
}

class _RunPatternSectionState extends ConsumerState<_RunPatternSection> {
  bool _seeded = false;
  bool _saving = false;
  String _phaseMode = 'batched';
  int _maxBooks = 4;
  String _audioOrder = 'shortest_first';
  bool _paused = false;
  final _quietStart = TextEditingController();
  final _quietEnd = TextEditingController();

  @override
  void dispose() {
    _quietStart.dispose();
    _quietEnd.dispose();
    super.dispose();
  }

  void _seedOnce(Map<String, dynamic> run) {
    if (_seeded) return;
    _seeded = true;
    _phaseMode = run['phase_mode']?.toString() ?? 'batched';
    _maxBooks = ((run['max_books_per_llm_phase'] as num?)?.toInt() ?? 4).clamp(
      1,
      20,
    );
    _audioOrder = run['audio_order']?.toString() ?? 'shortest_first';
    _paused = run['paused'] == true;
    final quiet = _map(run['quiet_hours']);
    _quietStart.text = quiet['start']?.toString() ?? '';
    _quietEnd.text = quiet['end']?.toString() ?? '';
  }

  static bool _validHhMm(String s) {
    final m = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(s.trim());
    if (m == null) return false;
    return int.parse(m.group(1)!) < 24 && int.parse(m.group(2)!) < 60;
  }

  Future<void> _save() async {
    final start = _quietStart.text.trim();
    final end = _quietEnd.text.trim();
    if ((start.isNotEmpty || end.isNotEmpty) &&
        !(_validHhMm(start) && _validHhMm(end))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Quiet hours need HH:MM, e.g. 22:00 to 06:00.'),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).putAdminSettings({
        'run_pattern': {
          'phase_mode': _phaseMode,
          'max_books_per_llm_phase': _maxBooks,
          'audio_order': _audioOrder,
          'paused': _paused,
          'quiet_hours': (start.isEmpty && end.isEmpty)
              ? null
              : {'start': start, 'end': end},
        },
      });
      ref.invalidate(adminSettingsProvider);
      ref.invalidate(adminQueueProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Run pattern saved.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ApiClient.friendlyAdminError(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(adminSettingsProvider);
    return settings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _loadError(
        context,
        'run pattern',
        e,
        () => ref.invalidate(adminSettingsProvider),
      ),
      data: (s) {
        _seedOnce(_map(s.values['run_pattern']));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'batched',
                  label: Text('Batched'),
                  icon: Icon(Icons.layers_outlined),
                ),
                ButtonSegment(
                  value: 'sequential',
                  label: Text('Sequential'),
                  icon: Icon(Icons.looks_one_outlined),
                ),
              ],
              selected: {_phaseMode},
              showSelectedIcon: false,
              onSelectionChanged: (picked) =>
                  setState(() => _phaseMode = picked.first),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: _maxBooks,
              decoration: const InputDecoration(
                labelText: 'Max books per LLM phase',
                border: OutlineInputBorder(),
              ),
              items: [
                for (var i = 1; i <= 20; i++)
                  DropdownMenuItem(value: i, child: Text('$i')),
              ],
              onChanged: (v) =>
                  setState(() => _maxBooks = (v ?? 4).clamp(1, 20)),
            ),
            const SizedBox(height: 12),
            Text('Audio order', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Shortest first'),
                  selected: _audioOrder == 'shortest_first',
                  onSelected: (_) =>
                      setState(() => _audioOrder = 'shortest_first'),
                ),
                ChoiceChip(
                  label: const Text('In order (FIFO)'),
                  selected: _audioOrder == 'fifo',
                  onSelected: (_) => setState(() => _audioOrder = 'fifo'),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Paused'),
              subtitle: const Text('No new GPU phase starts until resumed.'),
              value: _paused,
              onChanged: (v) => setState(() => _paused = v),
            ),
            const SizedBox(height: 4),
            Text(
              'Quiet hours (no GPU work)',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('quiet-start'),
                    controller: _quietStart,
                    decoration: const InputDecoration(
                      labelText: 'From (HH:MM)',
                      hintText: '22:00',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.datetime,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const ValueKey('quiet-end'),
                    controller: _quietEnd,
                    decoration: const InputDecoration(
                      labelText: 'Until (HH:MM)',
                      hintText: '06:00',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.datetime,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const _HelpText(
              'No new GPU phase starts inside this window (overnight '
              'windows wrap midnight). Leave both empty for none.',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('Save run pattern'),
            ),
          ],
        );
      },
    );
  }
}

// ---- 4 · Queue ----

/// Live scheduler status with pause/resume and per-book cancel +
/// move-to-top. Polls every 5 s while the screen is open.
class _QueueSection extends ConsumerStatefulWidget {
  const _QueueSection();

  @override
  ConsumerState<_QueueSection> createState() => _QueueSectionState();
}

class _QueueSectionState extends ConsumerState<_QueueSection> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) ref.invalidate(adminQueueProvider);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(ApiClient) action) async {
    try {
      await action(ref.read(apiClientProvider));
      ref.invalidate(adminQueueProvider);
      ref.invalidate(adminSettingsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ApiClient.friendlyAdminError(e))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(adminQueueProvider);
    // Keep showing the last data during a background refresh.
    final q = queue.value;
    if (q == null) {
      return queue.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _loadError(
          context,
          'the queue',
          e,
          () => ref.invalidate(adminQueueProvider),
        ),
        data: (_) => const SizedBox.shrink(),
      );
    }
    final paused = q.paused;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              paused ? Icons.pause_circle_rounded : Icons.play_circle_rounded,
              color: paused ? Colors.orange : Colors.green,
              semanticLabel: paused ? 'Queue paused' : 'Queue running',
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                paused
                    ? 'Paused${q.status != null ? ' · ${q.status}' : ''}'
                    : (q.status ?? 'Running'),
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: () =>
                  _run((api) => paused ? api.resumeQueue() : api.pauseQueue()),
              icon: Icon(
                paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              ),
              label: Text(paused ? 'Resume' : 'Pause'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (q.books.isEmpty)
          const Text('The queue is empty.')
        else
          for (final item in q.books)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                title: Text(
                  item.title.isNotEmpty ? item.title : item.slug,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // Unknown scheduler stages render verbatim: the cast
                // vocabulary grows server-side without app updates.
                subtitle: Text(
                  [
                    item.state,
                    item.stage,
                    item.detail,
                  ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Move to top',
                      icon: const Icon(Icons.vertical_align_top_rounded),
                      onPressed: () =>
                          _run((api) => api.prioritizeQueuedBook(item.slug)),
                    ),
                    IconButton(
                      tooltip: 'Cancel',
                      icon: Icon(
                        Icons.cancel_outlined,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      onPressed: () =>
                          _run((api) => api.cancelQueuedBook(item.slug)),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

// ---- Small shared pieces (same voice as Conversion settings) ----

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.titleMedium);
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

/// A select whose entries come from the server catalog. Shows the VRAM
/// hint under the label and a "weights not downloaded" warning when the
/// catalog says the weights are missing from the server cache.
class _CatalogDropdown extends StatelessWidget {
  final String label;
  final String? value;
  final List<_Option> options;
  final ValueChanged<String?> onChanged;
  const _CatalogDropdown({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final items = options.isEmpty && value != null
        ? [_Option(id: value!)]
        : options;
    final current = value != null && items.any((o) => o.id == value)
        ? value
        : null;
    final selected = current == null
        ? null
        : items.firstWhere((o) => o.id == current);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: current,
          decoration: InputDecoration(
            labelText: label,
            helperMaxLines: 5,
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final o in items)
              DropdownMenuItem(
                value: o.id,
                child: Text(o.label ?? o.id, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onChanged,
        ),
        if (selected?.description != null) _HelpText(selected!.description!),
        if (selected?.vramGb != null)
          _HelpText(
            'Needs about ${selected!.vramGb!.toStringAsFixed(1)} GB VRAM.',
          ),
        if (selected?.available == false)
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: _HelpText(
                  'Weights not downloaded on the server — expect a first-use download.',
                ),
              ),
            ],
          ),
      ],
    );
  }
}

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? v.map((k, val) => MapEntry(k.toString(), val)) : {};

/// Catalog entries: bare strings, or maps with id/name/description,
/// vram_gb and available. [availability] ({id: bool}) fills in a missing
/// per-entry `available`. The current value stays selectable even if the
/// catalog no longer lists it.
List<_Option> _optionsFrom(dynamic raw, dynamic availability, String? current) {
  final avail = _map(availability);
  final out = <_Option>[];
  if (raw is List) {
    for (final e in raw) {
      if (e is String && e.isNotEmpty) {
        out.add(_Option(id: e, available: avail[e] as bool?));
      } else if (e is Map) {
        final id = (e['id'] ?? e['model'] ?? e['value'])?.toString() ?? '';
        if (id.isEmpty) continue;
        out.add(
          _Option(
            id: id,
            label: e['name']?.toString(),
            vramGb: (e['vram_gb'] as num?)?.toDouble(),
            available: (e['available'] as bool?) ?? (avail[id] as bool?),
            description: e['description']?.toString(),
          ),
        );
      }
    }
  }
  if (current != null &&
      current.isNotEmpty &&
      !out.any((o) => o.id == current)) {
    out.insert(0, _Option(id: current));
  }
  return out;
}
