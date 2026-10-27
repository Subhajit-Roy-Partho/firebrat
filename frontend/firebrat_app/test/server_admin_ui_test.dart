import 'package:firebrat_app/screens/server_admin_screen.dart';
import 'package:firebrat_app/screens/server_setup_screen.dart';
import 'package:firebrat_app/models/server_admin.dart';
import 'package:firebrat_app/state/server_admin_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// IAM UI: role gating, setup screen, and the admin console. Layout cases
/// follow the conversion_settings_layout_test pattern (narrow screen +
/// 2x text, scrollUntilVisible through every section) so nothing
/// overflows on small phones.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('role gating', () {
    ProviderContainer forProfile(MeProfile? me) {
      final c = ProviderContainer(
        overrides: [meProvider.overrideWithValue(me)],
      );
      addTearDown(c.dispose);
      return c;
    }

    MeProfile p(String? role, {bool iam = true, bool setup = false}) =>
        MeProfile(
          uid: 'u',
          email: 'a@x.com',
          name: 'A',
          role: role,
          iamEnabled: iam,
          needsSetup: setup,
        );

    test('signed out / pre-IAM server keeps the old behaviour', () {
      final c = forProfile(null);
      expect(c.read(canUploadProvider), isTrue);
      expect(c.read(showAdminSectionProvider), isFalse);
      expect(c.read(needsSetupProvider), isFalse);
      expect(c.read(iamEnabledProvider), isFalse);
    });

    test('viewer can only listen; only admins see the console', () {
      expect(forProfile(p('viewer')).read(canUploadProvider), isFalse);
      expect(forProfile(p('viewer')).read(showAdminSectionProvider), isFalse);
      expect(forProfile(p('user')).read(canUploadProvider), isTrue);
      expect(forProfile(p('user')).read(showAdminSectionProvider), isFalse);
      expect(forProfile(p('admin')).read(canUploadProvider), isTrue);
      expect(forProfile(p('admin')).read(showAdminSectionProvider), isTrue);
    });

    test('IAM off: roles are not enforced, no admin UI for non-admins', () {
      final c = forProfile(p('viewer', iam: false));
      expect(c.read(canUploadProvider), isTrue);
      expect(c.read(showAdminSectionProvider), isFalse);
    });

    test('needsSetup surfaces only while the server asks for it', () {
      final c = forProfile(p(null, setup: true));
      expect(c.read(needsSetupProvider), isTrue);
      expect(c.read(canUploadProvider), isTrue);
    });
  });

  group('ServerSetupScreen', () {
    testWidgets('asks for the code and rejects empty input', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: ServerSetupScreen())),
      );
      await tester.pumpAndSettle();
      expect(find.text('Set up this server'), findsWidgets);
      expect(find.byKey(const ValueKey('setup-code')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('setup-submit')));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter the setup code from the server log.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('ServerAdminScreen', () {
    const users = [
      AdminUser(
        uid: 'u1',
        email: 'admin@x.com',
        name: '',
        role: 'admin',
        status: 'active',
        createdAt: null,
        invitedBy: null,
        lastSeen: null,
      ),
      AdminUser(
        uid: 'new@x.com',
        email: 'new@x.com',
        name: '',
        role: 'viewer',
        status: 'active',
        createdAt: null,
        invitedBy: null,
        lastSeen: null,
        claimed: false,
      ),
    ];
    AdminSettings envelope() => AdminSettings.fromJson({
      'values': {
        'llm': {'model': 'qwen3.5-9b', 'quantization': 'fp8'},
        'tts': {'engine': 'qwen3-tts-1.7b'},
        'run_pattern': {
          'phase_mode': 'batched',
          'max_books_per_llm_phase': 2,
          'audio_order': 'shortest_first',
          'paused': false,
          'quiet_hours': null,
        },
      },
      'options': {
        'llm': {
          'models': [
            {
              'id': 'qwen3.5-9b',
              'name': 'Qwen3.5 9B',
              'vram_gb': 20,
              'description': 'Full quality',
              'available': true,
            },
            {'id': 'qwen3.5-4b', 'vram_gb': 10, 'available': false},
          ],
          'quantizations': ['fp8'],
        },
        'tts': {
          'engines': [
            {'id': 'qwen3-tts-1.7b', 'available': true},
          ],
        },
      },
    });
    QueueStatus queue() => QueueStatus.fromJson({
      'paused': false,
      'status': 'Casting 1 book',
      'items': [
        {
          'slug': 'book-a',
          'title': 'Book A',
          'stage': 'casting characters',
          'state': 'running',
          'progress': 0.5,
        },
        {
          'slug': 'book-b',
          'title': 'Book B',
          // Unknown future stage: must render verbatim, never crash.
          'stage': 'dreaming electrons',
          'state': 'queued',
        },
      ],
    });

    ProviderScope harness() => ProviderScope(
      overrides: [
        meProvider.overrideWithValue(
          const MeProfile(
            uid: 'u1',
            email: 'a@x.com',
            name: 'A',
            role: 'admin',
            iamEnabled: true,
            needsSetup: false,
          ),
        ),
        adminUsersProvider.overrideWithValue(const AsyncValue.data(users)),
        adminSettingsProvider.overrideWithValue(AsyncValue.data(envelope())),
        adminQueueProvider.overrideWithValue(AsyncValue.data(queue())),
      ],
      child: const MaterialApp(home: ServerAdminScreen()),
    );

    testWidgets('all four sections render with catalog hints', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      final scrollable = find.byType(Scrollable).first;
      // ListView builds lazily: scroll each title into view before
      // asserting, the conversion_settings_layout_test pattern.
      for (final title in [
        '1 · Users',
        '2 · Models',
        '3 · Run pattern',
        '4 · Queue',
      ]) {
        await tester.scrollUntilVisible(
          find.text(title),
          200,
          scrollable: scrollable,
        );
        expect(find.text(title), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      // Invite row, claimed + unclaimed users (scroll back up: the
      // list only keeps nearby rows built).
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('invite-email')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const ValueKey('invite-email')), findsOneWidget);
      expect(find.text('admin@x.com'), findsOneWidget);
      expect(find.textContaining('invited, not signed in yet'), findsOneWidget);
      // Catalog selects show VRAM + weights warnings after scrolling.
      await tester.scrollUntilVisible(
        find.text('Save models'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('20.0 GB VRAM'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Save run pattern'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      // Run pattern controls + queue with verbatim unknown stage.
      await tester.scrollUntilVisible(
        find.text('Batched'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Batched'), findsOneWidget);
      expect(find.text('Shortest first'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('dreaming electrons'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow screen with large text does not overflow', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            meProvider.overrideWithValue(
              const MeProfile(
                uid: 'u1',
                email: 'a@x.com',
                name: 'A',
                role: 'admin',
                iamEnabled: true,
                needsSetup: false,
              ),
            ),
            adminUsersProvider.overrideWithValue(const AsyncValue.data(users)),
            adminSettingsProvider.overrideWithValue(
              AsyncValue.data(envelope()),
            ),
            adminQueueProvider.overrideWithValue(AsyncValue.data(queue())),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const ServerAdminScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final label in ['Save models', 'Save run pattern']) {
        await tester.scrollUntilVisible(
          find.text(label),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.scrollUntilVisible(
        find.textContaining('dreaming electrons'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
