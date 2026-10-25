import 'package:flutter_test/flutter_test.dart';
import 'package:firebrat_app/services/auth_service.dart';
import 'package:firebrat_app/services/drive_sync_service.dart';

void main() {
  group('Drive account email normalization', () {
    test('trims whitespace and ignores case', () {
      expect(
        AuthService.normalizeEmail('  Me.SubhajitRoy1999@Gmail.com  '),
        'me.subhajitroy1999@gmail.com',
      );
    });

    test('null and blank become null (treated as signed-out)', () {
      expect(AuthService.normalizeEmail(null), isNull);
      expect(AuthService.normalizeEmail(''), isNull);
      expect(AuthService.normalizeEmail('   '), isNull);
    });

    test('same mailbox in different case/whitespace matches', () {
      expect(
        AuthService.emailsMatch(
          'me.subhajitroy1999@gmail.com',
          '  ME.SUBHAJITROY1999@Gmail.COM ',
        ),
        isTrue,
      );
    });

    test('different device accounts do not match', () {
      expect(
        AuthService.emailsMatch(
          'me.subhajitroy1999@gmail.com',
          'someone.else@gmail.com',
        ),
        isFalse,
      );
    });

    test('missing side never matches', () {
      expect(AuthService.emailsMatch(null, 'a@gmail.com'), isFalse);
      expect(AuthService.emailsMatch('a@gmail.com', null), isFalse);
      expect(AuthService.emailsMatch(null, null), isFalse);
      expect(AuthService.emailsMatch('', 'a@gmail.com'), isFalse);
    });
  });

  group('Drive mismatch guidance', () {
    test('names both accounts and tells the user what to pick', () {
      final message = DriveSyncService.mismatchMessage(
        firebaseEmail: 'me.subhajitroy1999@gmail.com',
        googleEmail: '  OTHER@Gmail.com ',
      );
      expect(message, contains('me.subhajitroy1999@gmail.com'));
      expect(message, contains('other@gmail.com'));
      expect(message, contains('me.subhajitroy1999@gmail.com'));
      // Must not be the old unactionable text.
      expect(message, isNot(contains('Sign out and sign in with Google.')));
    });
  });
}
