import 'package:shared_preferences/shared_preferences.dart';

/// Remembers whether the first-run guide has been shown (or skipped) so it
/// only opens by itself once. It stays reachable from the drawer.
class TourStore {
  static const preferenceKey = 'app.tourSeen';

  static Future<bool> hasSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(preferenceKey) ?? false;
    } catch (_) {
      // Unreadable prefs must never trap the user in the guide.
      return true;
    }
  }

  static Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(preferenceKey, true);
    } catch (_) {}
  }
}
