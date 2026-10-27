/// Server-administration models (INTEGRATION2.md: accounts, roles, settings,
/// queue). All `fromJson` factories tolerate unknown keys and missing
/// optionals — like Manifest, the server may add keys clients ignore.
class MeProfile {
  final String uid;
  final String email;
  final String name;
  final String? role; // null when the account has no role yet
  final bool iamEnabled;
  final bool needsSetup;

  const MeProfile({
    required this.uid,
    required this.email,
    required this.name,
    required this.role,
    required this.iamEnabled,
    required this.needsSetup,
  });

  factory MeProfile.fromJson(Map<String, dynamic> json) => MeProfile(
    uid: json['uid']?.toString() ?? '',
    email: json['email']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    role: json['role']?.toString(),
    iamEnabled: json['iam_enabled'] == true,
    needsSetup: json['needs_setup'] == true,
  );
}

class AdminUser {
  final String uid; // invites not yet claimed may key by email
  final String email;
  final String name;
  final String role;
  final String? status; // 'active' | 'disabled'
  final String? createdAt;
  final String? invitedBy;
  final String? lastSeen;

  /// False for an invite whose email has not signed in yet (no uid).
  final bool claimed;

  /// Path segment for PATCH/DELETE: the uid, or the invited email.
  String get id => uid;

  /// Server omits status for old rows: treat as active.
  bool get isActive => (status ?? 'active') == 'active';

  const AdminUser({
    required this.uid,
    required this.email,
    required this.name,
    required this.role,
    required this.status,
    required this.createdAt,
    required this.invitedBy,
    required this.lastSeen,
    this.claimed = true,
  });

  factory AdminUser.fromJson(Map<String, dynamic> json) => AdminUser(
    claimed: (json['uid']?.toString() ?? '').isNotEmpty,
    uid: (json['uid']?.toString() ?? '').isNotEmpty
        ? json['uid'].toString()
        : json['email']?.toString() ?? '',
    email: json['email']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    role: json['role']?.toString() ?? 'viewer',
    status: json['status']?.toString(),
    createdAt: json['created_at']?.toString(),
    invitedBy: json['invited_by']?.toString(),
    lastSeen: json['last_seen']?.toString(),
  );
}

class AuditEntry {
  final dynamic id;
  final String? at;
  final String? actorUid;
  final String? action;
  final String? target;
  final String? detail;

  const AuditEntry({
    required this.id,
    required this.at,
    required this.actorUid,
    required this.action,
    required this.target,
    required this.detail,
  });

  factory AuditEntry.fromJson(Map<String, dynamic> json) => AuditEntry(
    id: json['id'],
    at: json['at']?.toString(),
    actorUid: json['actor_uid']?.toString(),
    action: json['action']?.toString(),
    target: json['target']?.toString(),
    detail: json['detail']?.toString(),
  );
}

/// Device-controlled settings catalog (values/options/availability/notes).
/// Shapes are server-defined and may grow — keep the raw maps, never
/// assume a fixed value schema here.
class AdminSettings {
  final Map<String, dynamic> values;
  final Map<String, dynamic> options;
  final Map<String, dynamic> availability;
  final dynamic notes;

  const AdminSettings({
    required this.values,
    required this.options,
    required this.availability,
    required this.notes,
  });

  static Map<String, dynamic> _asMap(dynamic v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return const {};
  }

  factory AdminSettings.fromJson(Map<String, dynamic> json) => AdminSettings(
    values: _asMap(json['values']),
    options: _asMap(json['options']),
    availability: _asMap(json['availability']),
    notes: json['notes'],
  );
}

class QueuedBook {
  final String slug;
  final String title;
  final String? stage;
  final String? state;
  final double? progress;
  final String? detail;

  const QueuedBook({
    required this.slug,
    required this.title,
    required this.stage,
    required this.state,
    this.progress,
    this.detail,
  });

  factory QueuedBook.fromJson(Map<String, dynamic> json) => QueuedBook(
    slug: (json['slug'] ?? json['book_id'])?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    stage: json['stage']?.toString(),
    state: (json['state'] ?? json['status'] ?? json['terminal'])?.toString(),
    progress: (json['progress'] as num?)?.toDouble(),
    detail: json['detail']?.toString(),
  );
}

/// Scheduler status + per-book stages. Unknown scheduler keys ride along
/// in [raw]; [paused], [status] and [books] are the only interpreted
/// fields. The book list is found under books/items/jobs/queue (or the
/// first list of slug-bearing maps anywhere), so scheduler versions that
/// rename the key keep rendering. Stage text stays a verbatim string.
class QueueStatus {
  final bool paused;
  final String? status;
  final List<QueuedBook> books;
  final Map<String, dynamic> raw;

  const QueueStatus({
    required this.paused,
    required this.books,
    required this.raw,
    this.status,
  });

  static List? _findList(dynamic node, [int depth = 0]) {
    if (node is! Map || depth > 3) return null;
    for (final k in const ['books', 'items', 'jobs', 'queue']) {
      final v = node[k];
      if (v is List) return v;
    }
    for (final v in node.values) {
      final found = _findList(v, depth + 1);
      if (found != null) return found;
    }
    return null;
  }

  factory QueueStatus.fromJson(Map<String, dynamic> json) {
    final list = _findList(json) ?? const [];
    final books = list
        .whereType<Map>()
        .map((e) => QueuedBook.fromJson(Map<String, dynamic>.from(e)))
        .where((b) => b.slug.isNotEmpty)
        .toList();
    final sched = json['scheduler'] is Map
        ? json['scheduler'] as Map
        : const {};
    final st = json['status'] ?? sched['detail'] ?? json['scheduler_status'];
    return QueueStatus(
      paused: json['paused'] == true,
      status: st is String ? st : null,
      books: books,
      raw: Map<String, dynamic>.from(json),
    );
  }
}
