import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Guest access creates no Firebase account and grants no server permissions.
/// Remember the choice so restarting does not force a login prompt.
class GuestAccessNotifier extends Notifier<bool> {
  static const preferenceKey = 'app.continueAsGuest';
  bool _choiceMade = false;

  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_choiceMade && ref.mounted) {
      state = prefs.getBool(preferenceKey) ?? false;
    }
  }

  Future<void> setGuest(bool enabled) async {
    _choiceMade = true;
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(preferenceKey, enabled);
  }
}

final guestAccessProvider =
    NotifierProvider<GuestAccessNotifier, bool>(GuestAccessNotifier.new);
