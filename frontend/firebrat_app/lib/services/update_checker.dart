import 'dart:io';

import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Asks Google Play whether a newer build is published and, if so, offers to
/// open the store page. Only Play-installed Android builds can answer (a
/// sideloaded APK or iOS build gets no prompt). "Later" snoozes the prompt
/// for [snooze] so it never nags on every launch.
class UpdateChecker {
  UpdateChecker._();

  static const playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.firebrat.firebrat_app';
  static const _snoozeKey = 'update_prompt_snoozed_until';
  static const snooze = Duration(days: 3);

  /// Latest Play version code when it is newer than this install, else null.
  static Future<int?> availableUpdate() async {
    if (!Platform.isAndroid) return null;
    try {
      final info = await InAppUpdate.checkForUpdate();
      if (info.updateAvailability == UpdateAvailability.updateAvailable) {
        return info.availableVersionCode;
      }
    } catch (_) {
      // Not installed from Play, Play missing, or offline: nothing to offer.
    }
    return null;
  }

  static Future<void> openStore() async {
    final market = Uri.parse('market://details?id=com.firebrat.firebrat_app');
    if (await canLaunchUrl(market) &&
        await launchUrl(market, mode: LaunchMode.externalApplication))
      return;
    await launchUrl(
      Uri.parse(playStoreUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  /// Call once after the first frame; shows a dialog when an update exists
  /// and the user has not snoozed it. [force] (Settings → "Check for updates")
  /// ignores the snooze and reports "up to date".
  static Future<void> maybePrompt(
    BuildContext context, {
    bool force = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt(_snoozeKey) ?? 0;
    if (!force && DateTime.now().millisecondsSinceEpoch < until) return;
    final latest = await availableUpdate();
    if (!context.mounted) return;
    if (latest == null) {
      if (force) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You have the latest version.')),
        );
      }
      return;
    }
    final update = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update available'),
        content: const Text(
          'A new version of Firebrat is on Google Play with improvements and fixes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (update == true) {
      await openStore();
    } else {
      await prefs.setInt(
        _snoozeKey,
        DateTime.now().add(snooze).millisecondsSinceEpoch,
      );
    }
  }
}
