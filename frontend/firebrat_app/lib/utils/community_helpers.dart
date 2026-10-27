import 'package:flutter/material.dart';

/// True when [uri] points at the Internet Archive over HTTPS — either the
/// bare host or any subdomain (e.g. ia801234.us.archive.org).
bool isAllowedArchiveHost(Uri uri) {
  if (uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  return host == 'archive.org' || host.endsWith('.archive.org');
}

/// Parses [url] and checks it against [isAllowedArchiveHost]. Malformed
/// URLs are refused rather than throwing.
bool isAllowedArchiveUrl(String url) {
  try {
    return isAllowedArchiveHost(Uri.parse(url));
  } catch (_) {
    return false;
  }
}

/// Archive identifier regex shared with the community site (see
/// community/SPEC.md `parseArchiveUrl`).
final RegExp archiveIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{2,99}$');

/// Extracts the Internet Archive identifier from [archiveUrl] (last
/// non-empty path segment). Throws [FormatException] when the URL has no
/// usable segment or the identifier fails validation.
String archiveIdFromUrl(String archiveUrl) {
  final uri = Uri.parse(archiveUrl);
  final segments =
      uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  if (segments.isEmpty) {
    throw FormatException('No identifier found in "$archiveUrl"');
  }
  final id = segments.last;
  if (!archiveIdPattern.hasMatch(id)) {
    throw FormatException('Invalid archive identifier "$id"');
  }
  return id;
}

/// Mean star rating, or 0.0 when nothing has been rated yet.
double ratingAverage(num ratingSum, num ratingCount) {
  if (ratingCount <= 0) return 0.0;
  return ratingSum / ratingCount;
}

/// Deterministic djb2 hash of [title] — seeds the generated cover so the
/// same book always gets the same gradient.
int coverSeed(String title) {
  var hash = 5381;
  for (final unit in title.codeUnits) {
    hash = ((hash << 5) + hash + unit) & 0xFFFFFFFF;
  }
  return hash;
}

/// Two deterministic gradient colors derived from the title hash (hue from
/// the seed, fixed pleasant saturation/lightness pair).
List<Color> coverColors(String title) {
  final seed = coverSeed(title);
  final hue = (seed % 360).toDouble();
  final hue2 = ((seed ~/ 7) % 360).toDouble();
  return [
    HSLColor.fromAHSL(1.0, hue, 0.55, 0.45).toColor(),
    HSLColor.fromAHSL(1.0, hue2, 0.6, 0.32).toColor(),
  ];
}

/// Human duration for a book package: "7h 21m", "45m", "30s", or "—" for 0.
String formatDuration(int totalDurationMs) {
  if (totalDurationMs <= 0) return '—';
  final totalSeconds = totalDurationMs ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  if (minutes > 0) return '${minutes}m';
  return '${seconds}s';
}
