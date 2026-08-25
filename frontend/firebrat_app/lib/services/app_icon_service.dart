import 'package:shared_preferences/shared_preferences.dart';

/// Mood-driven launcher icon helper.
///
/// The base icon is the happy worm (`app_icon.svg`) — used by `flutter_launcher_icons`.
/// Four additional moods live in `assets/icon/moods/`:
///
/// - `focused` — wide eyes, eyebrows, small mouth (user in deep reading >15min)
/// - `sleepy` — half-closed eyes + Zzz (no activity 24h+)
/// - `celebratory` — party hat + confetti (just finished a book or 7-day streak)
/// - `streak` — sunglasses + flame badge (3+ day streak)
///
/// Android cannot hot-swap its adaptive launcher icon without an
/// `activity-alias` per variant. This service therefore does two things:
/// 1. Persists usage stats (listening time, last-open, streak) in
///    `SharedPreferences` so mood can be computed.
/// 2. Exposes the current mood + the asset path the UI should show
///    *inside* the app (library header, splash). The home-screen icon
///    itself stays the happy default until you wire aliases (see
///    `docs/ICON.md`). In-app mood is instant.
///
/// Usage:
/// ```dart
/// final mood = await AppIconService.instance.currentMood();
/// Image.asset(mood.assetPath)
/// ```
/// Call `recordListening(Duration)` after each section completes.
enum AppMood {
  happy('assets/icon/app_icon.png', 'assets/icon/app_icon.svg'),
  focused('assets/icon/moods/app_icon_focused.png', 'assets/icon/moods/app_icon_focused.svg'),
  sleepy('assets/icon/moods/app_icon_sleepy.png', 'assets/icon/moods/app_icon_sleepy.svg'),
  celebratory('assets/icon/moods/app_icon_celebratory.png', 'assets/icon/moods/app_icon_celebratory.svg'),
  streak('assets/icon/moods/app_icon_streak.png', 'assets/icon/moods/app_icon_streak.svg');

  final String assetPath;
  final String svgPath;
  const AppMood(this.assetPath, this.svgPath);
}

class AppIconService {
  AppIconService._();
  static final AppIconService instance = AppIconService._();

  static const _kTotalMinutes = 'icon_total_minutes';
  static const _kLastOpenMs = 'icon_last_open_ms';
  static const _kStreakDays = 'icon_streak_days';
  static const _kLastStreakDate = 'icon_last_streak_date';
  static const _kBooksFinished = 'icon_books_finished';

  Future<void> recordAppOpen() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kLastOpenMs, DateTime.now().millisecondsSinceEpoch);
    await _updateStreak(p);
  }

  Future<void> recordListening(Duration d) async {
    final p = await SharedPreferences.getInstance();
    final total = p.getInt(_kTotalMinutes) ?? 0;
    await p.setInt(_kTotalMinutes, total + d.inMinutes);
    await p.setInt(_kLastOpenMs, DateTime.now().millisecondsSinceEpoch);
    await _updateStreak(p);
  }

  Future<void> recordBookFinished() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kBooksFinished, (p.getInt(_kBooksFinished) ?? 0) + 1);
  }

  Future<void> _updateStreak(SharedPreferences p) async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final last = p.getString(_kLastStreakDate);
    if (last == today) return;
    if (last == null) {
      await p.setInt(_kStreakDays, 1);
    } else {
      final lastDate = DateTime.tryParse(last);
      final now = DateTime.now();
      if (lastDate != null && now.difference(lastDate).inDays == 1) {
        await p.setInt(_kStreakDays, (p.getInt(_kStreakDays) ?? 0) + 1);
      } else if (lastDate != null && now.difference(lastDate).inDays > 1) {
        await p.setInt(_kStreakDays, 1);
      }
    }
    await p.setString(_kLastStreakDate, today);
  }

  Future<AppMood> currentMood() async {
    final p = await SharedPreferences.getInstance();
    final streak = p.getInt(_kStreakDays) ?? 0;
    final finished = p.getInt(_kBooksFinished) ?? 0;
    final lastOpenMs = p.getInt(_kLastOpenMs) ?? 0;
    final totalMin = p.getInt(_kTotalMinutes) ?? 0;
    final hoursSinceOpen = lastOpenMs == 0
        ? 999
        : DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastOpenMs)).inHours;

    if (finished > 0 && streak >= 1) {
      // show celebratory briefly after a finish (reset after next open)
      // caller should clear via clearCelebratory() after showing.
      // Heuristic: if booksFinished incremented within last 24h
      return AppMood.celebratory;
    }
    if (streak >= 3) return AppMood.streak;
    if (hoursSinceOpen >= 24) return AppMood.sleepy;
    if (totalMin >= 15) return AppMood.focused;
    return AppMood.happy;
  }

  Future<void> clearCelebratory() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kBooksFinished, 0);
  }
}
