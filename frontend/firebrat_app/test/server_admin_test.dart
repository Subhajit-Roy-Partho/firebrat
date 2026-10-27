import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:firebrat_app/models/server_admin.dart';
import 'package:firebrat_app/services/api_client.dart';
import 'package:firebrat_app/state/library_providers.dart';
import 'package:firebrat_app/state/server_admin_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAdminApi extends ApiClient {
  MeProfile me;
  String? lastBootstrapCode;
  FakeAdminApi(this.me) : super(baseUrl: 'http://localhost:1');

  @override
  Future<MeProfile> getMe() async => me;

  @override
  Future<void> bootstrapSetup(String code) async {
    lastBootstrapCode = code;
    me = MeProfile(
      uid: me.uid,
      email: me.email,
      name: me.name,
      role: 'admin',
      iamEnabled: true,
      needsSetup: false,
    );
  }

  @override
  Future<List<AdminUser>> listAdminUsers() async => const [];

  @override
  Future<AdminSettings> getAdminSettings() async => const AdminSettings(
    values: {},
    options: {},
    availability: {},
    notes: null,
  );

  @override
  Future<QueueStatus> getQueue() async =>
      const QueueStatus(paused: false, books: [], raw: {});
}

/// Records requests and answers from a route table; no network.
class FakeAdapter implements HttpClientAdapter {
  final Map<String, ResponseBody Function(RequestOptions)> routes;
  final List<RequestOptions> seen = [];
  FakeAdapter(this.routes);

  static ResponseBody json(Object body, [int status = 200]) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    final h = routes['${options.method} ${options.path}'];
    if (h == null) return json({'detail': 'no route'}, 404);
    return h(options);
  }

  @override
  void close({bool force = false}) {}
}

ApiClient apiWith(FakeAdapter adapter) {
  final api = ApiClient(baseUrl: 'http://fake');
  api.dio.httpClientAdapter = adapter;
  return api;
}

MeProfile profile({
  String role = 'user',
  bool iam = true,
  bool setup = false,
}) => MeProfile(
  uid: 'u1',
  email: 'a@example.com',
  name: 'A',
  role: role,
  iamEnabled: iam,
  needsSetup: setup,
);

ProviderContainer makeContainer(FakeAdminApi api) {
  final container = ProviderContainer(
    overrides: [apiClientProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MeProfile.fromJson tolerates unknown keys and missing role', () {
    final me = MeProfile.fromJson({
      'uid': 'u1',
      'email': 'a@example.com',
      'name': 'A',
      'role': null,
      'iam_enabled': true,
      'needs_setup': true,
      'future_key': {'nested': 1},
    });
    expect(me.uid, 'u1');
    expect(me.role, isNull);
    expect(me.iamEnabled, isTrue);
    expect(me.needsSetup, isTrue);
    // Missing flags default false (older servers).
    final old = MeProfile.fromJson({'uid': 'u', 'email': 'e', 'name': 'n'});
    expect(old.iamEnabled, isFalse);
    expect(old.needsSetup, isFalse);
    expect(old.role, isNull);
  });

  test('AdminUser/AdminSettings/QueueStatus tolerate partial payloads', () {
    final invite = AdminUser.fromJson({
      'email': 'b@example.com',
      'role': 'viewer',
      'extra': 1,
    });
    expect(invite.uid, 'b@example.com');
    expect(invite.status, isNull);

    final settings = AdminSettings.fromJson({
      'values': {
        'llm': {'model': 'qwen3.5-4b'},
      },
      'options': {},
      'unknown_top_level': true,
    });
    expect(settings.values['llm'], isNotNull);
    expect(settings.availability, isEmpty);

    final queue = QueueStatus.fromJson({
      'paused': true,
      'books': [
        {
          'slug': 'book-a',
          'stage': 'casting characters',
          'mystery': 'kept-in-raw',
        },
      ],
      'scheduler': {'uptime': 5},
    });
    expect(queue.paused, isTrue);
    expect(queue.books.single.slug, 'book-a');
    expect(queue.books.single.stage, 'casting characters');
    expect(queue.raw['scheduler'], isNotNull);
  });

  test('DioException literals: 403 viewer message, other details kept', () {
    RequestOptions req() => RequestOptions(path: '/books/upload');
    final forbidden = DioException(
      requestOptions: req(),
      response: Response(
        requestOptions: req(),
        statusCode: 403,
        data: {'detail': 'Requires upload role'},
      ),
      type: DioExceptionType.badResponse,
    );
    expect(ApiClient.friendlyUploadError(forbidden), 'Requires upload role');

    final forbiddenBare = DioException(
      requestOptions: req(),
      response: Response(requestOptions: req(), statusCode: 403, data: {}),
      type: DioExceptionType.badResponse,
    );
    expect(
      ApiClient.friendlyUploadError(forbiddenBare),
      contains('only listen'),
    );
  });

  test(
    'admin section hidden when IAM off; legacy admin hook shows it',
    () async {
      SharedPreferences.setMockInitialValues({});
      // IAM off, plain user: everything hidden.
      final plain = makeContainer(
        FakeAdminApi(profile(role: 'user', iam: false)),
      );
      await plain.read(serverAdminProvider.notifier).refreshMe();
      expect(plain.read(iamEnabledProvider), isFalse);
      expect(plain.read(isAdminProvider), isFalse);
      expect(plain.read(isLegacyAdminProvider), isFalse);
      expect(plain.read(showAdminSectionProvider), isFalse);

      // IAM off but admin-role profile: legacy hook surfaces admin UI.
      final legacy = makeContainer(
        FakeAdminApi(profile(role: 'admin', iam: false)),
      );
      await legacy.read(serverAdminProvider.notifier).refreshMe();
      expect(legacy.read(isLegacyAdminProvider), isTrue);
      expect(legacy.read(showAdminSectionProvider), isTrue);

      // IAM on, non-admin: hidden.
      final user = makeContainer(
        FakeAdminApi(profile(role: 'viewer', iam: true)),
      );
      await user.read(serverAdminProvider.notifier).refreshMe();
      expect(user.read(iamEnabledProvider), isTrue);
      expect(user.read(showAdminSectionProvider), isFalse);
      expect(user.read(canUploadProvider), isFalse);

      // IAM on, admin: visible.
      final admin = makeContainer(
        FakeAdminApi(profile(role: 'admin', iam: true)),
      );
      await admin.read(serverAdminProvider.notifier).refreshMe();
      expect(admin.read(isAdminProvider), isTrue);
      expect(admin.read(showAdminSectionProvider), isTrue);
    },
  );

  test(
    'needsSetup mirrors /me and bootstrap claims admin without logging',
    () async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeAdminApi(profile(role: 'user', iam: true, setup: true));
      final container = makeContainer(api);
      await container.read(serverAdminProvider.notifier).refreshMe();
      expect(container.read(needsSetupProvider), isTrue);

      await container.read(serverAdminProvider.notifier).bootstrap('code-123');
      expect(api.lastBootstrapCode, 'code-123');
      expect(container.read(needsSetupProvider), isFalse);
      expect(container.read(isAdminProvider), isTrue);
    },
  );

  group('ApiClient admin methods over a fake adapter', () {
    test('getMe and bootstrapSetup', () async {
      final a = FakeAdapter({
        'GET /me': (_) => FakeAdapter.json({
          'uid': 'u1',
          'email': 'a@x.com',
          'name': 'A',
          'role': null,
          'iam_enabled': true,
          'needs_setup': true,
        }),
        'POST /admin/bootstrap': (_) =>
            FakeAdapter.json({'uid': 'u1', 'role': 'admin'}),
      });
      final api = apiWith(a);
      final me = await api.getMe();
      expect(me.needsSetup, isTrue);
      expect(me.role, isNull);
      await api.bootstrapSetup('ABCDE12345');
      expect(a.seen.last.data, {'code': 'ABCDE12345'});
    });

    test('bootstrap 403/410/429 give friendly messages', () async {
      for (final c in [
        [403, 'invalid setup code', 'invalid setup code'],
        [410, null, 'This server is already set up.'],
        [429, null, 'Too many attempts. Wait a few minutes and try again.'],
      ]) {
        final api = apiWith(
          FakeAdapter({
            'POST /admin/bootstrap': (_) => FakeAdapter.json(
              c[1] == null ? {} : {'detail': c[1]},
              c[0] as int,
            ),
          }),
        );
        try {
          await api.bootstrapSetup('x');
          fail('expected DioException');
        } on DioException catch (e) {
          expect(ApiClient.friendlyAdminError(e), c[2]);
        }
      }
    });

    test(
      'users: list merges unclaimed invites; invite/patch/delete paths',
      () async {
        final a = FakeAdapter({
          'GET /admin/users': (_) => FakeAdapter.json({
            'users': [
              {
                'uid': 'u1',
                'email': 'a@x.com',
                'name': 'A',
                'role': 'admin',
                'status': 'active',
              },
              {
                'uid': 'u2',
                'email': 'b@x.com',
                'role': 'user',
                'status': 'disabled',
              },
            ],
            'invites': [
              {'email': 'new@x.com', 'role': 'viewer', 'claimed_uid': null},
              {'email': 'b@x.com', 'role': 'user', 'claimed_uid': 'u2'},
            ],
          }),
          'POST /admin/users': (_) => FakeAdapter.json({'email': 'new@x.com'}),
          'PATCH /admin/users/u2': (_) => FakeAdapter.json({}),
          'DELETE /admin/users/new%40x.com': (_) =>
              FakeAdapter.json({'deleted': 'x'}),
        });
        final api = apiWith(a);
        final users = await api.listAdminUsers();
        expect(users.map((u) => u.email), ['a@x.com', 'b@x.com', 'new@x.com']);
        expect(users[1].isActive, isFalse);
        expect(users[2].claimed, isFalse);
        await api.inviteUser(email: 'new@x.com', role: 'viewer');
        expect(a.seen.last.data, {'email': 'new@x.com', 'role': 'viewer'});
        await api.updateUser('u2', role: 'viewer', status: 'active');
        expect(a.seen.last.data, {'role': 'viewer', 'status': 'active'});
        await api.removeUser('new@x.com');
        expect(a.seen.last.method, 'DELETE');
      },
    );

    test('last-admin 409 surfaces the server detail', () async {
      final api = apiWith(
        FakeAdapter({
          'PATCH /admin/users/u1': (_) =>
              FakeAdapter.json({'detail': 'cannot demote the last admin'}, 409),
        }),
      );
      try {
        await api.updateUser('u1', role: 'user');
        fail('expected DioException');
      } on DioException catch (e) {
        expect(ApiClient.friendlyAdminError(e), 'cannot demote the last admin');
      }
    });

    test(
      'settings: get parses the real envelope, put sends {values}',
      () async {
        final a = FakeAdapter({
          'GET /admin/settings': (_) => FakeAdapter.json({
            'values': {
              'llm': {'model': 'qwen3.5-9b', 'quantization': 'fp8'},
            },
            'options': {
              'llm': {
                'models': [
                  {'id': 'qwen3.5-9b', 'vram_gb': 11, 'available': false},
                ],
                'quantizations': ['fp8'],
              },
            },
            'availability': {'hf_cache': '/x'},
            'notes': 'n',
          }),
          'PUT /admin/settings': (_) => FakeAdapter.json({'values': {}}),
        });
        final api = apiWith(a);
        final s = await api.getAdminSettings();
        expect(s.options['llm'], isA<Map>());
        await api.putAdminSettings({
          'run_pattern': {'paused': true},
        });
        expect(a.seen.last.data, {
          'values': {
            'run_pattern': {'paused': true},
          },
        });
      },
    );

    test(
      'queue: parses scheduler.books, controls hit the right routes',
      () async {
        final a = FakeAdapter({
          'GET /admin/queue': (_) => FakeAdapter.json({
            'paused': true,
            'scheduler': {
              'available': true,
              'running': true,
              'detail': 'casting',
              'books': [
                {
                  'slug': 'book-a',
                  'stage': 'casting characters',
                  'progress': 0.5,
                  'terminal': null,
                },
                {'slug': 'book-b', 'stage': 'dreaming electrons'},
              ],
            },
          }),
          'POST /admin/queue/pause': (_) => FakeAdapter.json({}),
          'POST /admin/queue/resume': (_) => FakeAdapter.json({}),
          'POST /admin/queue/book-a/cancel': (_) => FakeAdapter.json({}),
          'POST /admin/queue/book-a/priority': (_) => FakeAdapter.json({}),
        });
        final api = apiWith(a);
        final q = await api.getQueue();
        expect(q.paused, isTrue);
        expect(q.status, 'casting');
        expect(q.books.map((b) => b.slug), ['book-a', 'book-b']);
        expect(q.books[1].stage, 'dreaming electrons');
        await api.pauseQueue();
        await api.resumeQueue();
        await api.cancelQueuedBook('book-a');
        await api.prioritizeQueuedBook('book-a');
        expect(a.seen.last.data, {'top': true});
        expect(a.seen.length, 5);
      },
    );

    test('403 from an admin route is a friendly message', () async {
      final api = apiWith(
        FakeAdapter({
          'GET /admin/users': (_) =>
              FakeAdapter.json({'detail': 'admin required'}, 403),
        }),
      );
      try {
        await api.listAdminUsers();
        fail('expected DioException');
      } on DioException catch (e) {
        expect(ApiClient.friendlyAdminError(e), 'admin required');
      }
    });
  });
}
