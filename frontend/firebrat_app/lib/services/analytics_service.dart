import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/widgets.dart';

/// Firebase Analytics: how the app is used, never what it contains.
/// Privacy rule enforced here by construction — events carry counts and
/// ids (book_id slugs, section counts), never titles, filenames, emails,
/// or file contents. All calls are best-effort (analytics must never
/// break a user flow).
class AnalyticsService {
  AnalyticsService._();
  static final AnalyticsService instance = AnalyticsService._();

  FirebaseAnalytics get analytics => FirebaseAnalytics.instance;

  /// Screen-view observer, or empty when Firebase isn't initialized
  /// (flutter_test harness, misconfigured build). Analytics must never
  /// break the widget tree.
  static List<NavigatorObserver> observerOrNull() {
    try {
      return [FirebaseAnalyticsObserver(analytics: FirebaseAnalytics.instance)];
    } catch (_) {
      return const [];
    }
  }

  Future<void> logLogin(String method) async {
    try {
      await analytics.logLogin(loginMethod: method);
    } catch (_) {}
  }

  Future<void> logBookDownloaded({int sizeMb = 0}) async {
    try {
      await analytics.logEvent(name: 'book_downloaded', parameters: {'size_mb': sizeMb});
    } catch (_) {}
  }

  Future<void> logBookOpened({required int sectionCount}) async {
    try {
      await analytics.logEvent(
          name: 'book_opened', parameters: {'section_count': sectionCount});
    } catch (_) {}
  }

  Future<void> logConversionStarted({required String mode}) async {
    try {
      await analytics.logEvent(name: 'conversion_started', parameters: {'mode': mode});
    } catch (_) {}
  }

  Future<void> logModelDownloaded({required String modelId}) async {
    try {
      await analytics.logEvent(name: 'model_downloaded', parameters: {'model_id': modelId});
    } catch (_) {}
  }

  Future<void> logDriveSync({required String action}) async {
    try {
      await analytics.logEvent(name: 'drive_sync', parameters: {'action': action});
    } catch (_) {}
  }
}
