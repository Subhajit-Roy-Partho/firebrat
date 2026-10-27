import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/server_admin.dart';
import '../services/api_client.dart';
import '../utils/server_url.dart';
import 'library_providers.dart';

/// Server administration state (INTEGRATION2.md): the signed-in account's
/// [MeProfile] plus whether the server enforces accounts/roles. Entirely
/// OFF/backward-compatible — when `iam_enabled` is false everything stays
/// hidden unless the account is the legacy admin (see
/// [isLegacyAdminProvider]).
class ServerAdminState {
  final MeProfile? me;
  final bool loading;
  final String? error;
  final bool iamEnabled;

  const ServerAdminState({
    this.me,
    this.loading = false,
    this.error,
    this.iamEnabled = false,
  });

  ServerAdminState copyWith({
    MeProfile? me,
    bool clearMe = false,
    bool? loading,
    String? error,
    bool? iamEnabled,
  }) => ServerAdminState(
    me: clearMe ? null : (me ?? this.me),
    loading: loading ?? this.loading,
    error: error,
    iamEnabled: iamEnabled ?? this.iamEnabled,
  );
}

class ServerAdminNotifier extends Notifier<ServerAdminState> {
  @override
  ServerAdminState build() => const ServerAdminState();

  /// Loads GET /me (and with it `iam_enabled`/`needs_setup`). When
  /// [baseUrlOverride] is given (a URL field's current text, possibly
  /// unsaved), the probe goes there instead of the saved URL — same
  /// pattern as ServerBooksNotifier.
  Future<void> refreshMe({String? baseUrlOverride}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final ApiClient api;
      if (baseUrlOverride != null && baseUrlOverride.trim().isNotEmpty) {
        api = ApiClient(baseUrl: normalizeServerUrl(baseUrlOverride));
      } else {
        api = ref.read(apiClientProvider);
      }
      final me = await api.getMe();
      state = state.copyWith(loading: false, me: me, iamEnabled: me.iamEnabled);
    } catch (e) {
      // Old servers have no /me (404), or the server is unreachable /
      // the user is signed out: drop any previous profile so admin UI and
      // role gates fall back to the old, permissive behaviour.
      state = ServerAdminState(error: '$e');
    }
  }

  /// Forget the profile (sign-out, server URL change).
  void clear() => state = const ServerAdminState();

  /// First-run setup: presents the one-time setup code, then reloads /me
  /// (the caller becomes admin). The code is passed through, never stored.
  Future<void> bootstrap(String code, {String? baseUrlOverride}) async {
    final ApiClient api;
    if (baseUrlOverride != null && baseUrlOverride.trim().isNotEmpty) {
      api = ApiClient(baseUrl: normalizeServerUrl(baseUrlOverride));
    } else {
      api = ref.read(apiClientProvider);
    }
    await api.bootstrapSetup(code);
    await refreshMe(baseUrlOverride: baseUrlOverride);
  }

  void clearError() {
    state = ServerAdminState(me: state.me, iamEnabled: state.iamEnabled);
  }
}

final serverAdminProvider =
    NotifierProvider<ServerAdminNotifier, ServerAdminState>(
      ServerAdminNotifier.new,
    );

/// The signed-in profile, null until [ServerAdminNotifier.refreshMe] runs.
final meProvider = Provider<MeProfile?>(
  (ref) => ref.watch(serverAdminProvider).me,
);

/// Role string ('admin' | 'user' | 'viewer'), null when role-less/signed out.
final currentRoleProvider = Provider<String?>(
  (ref) => ref.watch(meProvider)?.role,
);

final isAdminProvider = Provider<bool>(
  (ref) => ref.watch(currentRoleProvider) == 'admin',
);

/// True only during first-run setup (IAM on, no admin exists yet).
final needsSetupProvider = Provider<bool>(
  (ref) => ref.watch(meProvider)?.needsSetup ?? false,
);

final iamEnabledProvider = Provider<bool>(
  (ref) => ref.watch(meProvider)?.iamEnabled ?? false,
);

/// Heuristic hook for pre-IAM deployments: an admin-role profile seen
/// while `iam_enabled` is false (e.g. a legacy `FIREBRAT_ALLOWED_USER_IDS`
/// admin before the IAM tables exist). Screens hide admin UI unless
/// [showAdminSectionProvider] is true; tests can override this provider to
/// force either branch.
final isLegacyAdminProvider = Provider<bool>((ref) {
  final s = ref.watch(serverAdminProvider);
  return !s.iamEnabled && s.me?.role == 'admin';
});

/// Single gate for all admin UI: visible when IAM is on for admins, or for
/// the legacy-admin heuristic. Non-admins never see admin UI.
final showAdminSectionProvider = Provider<bool>((ref) {
  if (!ref.watch(iamEnabledProvider) && !ref.watch(isLegacyAdminProvider)) {
    return false;
  }
  return ref.watch(isAdminProvider) || ref.watch(isLegacyAdminProvider);
});

/// Viewers (and only viewers) lose uploads. Unknown/signed-out/pre-IAM
/// keeps the old behaviour (allowed) so public servers never regress.
/// Only meaningful while IAM is on: with IAM off roles are not enforced.
final canUploadProvider = Provider<bool>((ref) {
  if (!ref.watch(iamEnabledProvider)) return true;
  return ref.watch(currentRoleProvider) != 'viewer';
});

// ---- Admin console data (screens override these in tests) ----

final adminUsersProvider = FutureProvider.autoDispose<List<AdminUser>>(
  (ref) => ref.watch(apiClientProvider).listAdminUsers(),
);

final adminSettingsProvider = FutureProvider.autoDispose<AdminSettings>(
  (ref) => ref.watch(apiClientProvider).getAdminSettings(),
);

final adminQueueProvider = FutureProvider.autoDispose<QueueStatus>(
  (ref) => ref.watch(apiClientProvider).getQueue(),
);
