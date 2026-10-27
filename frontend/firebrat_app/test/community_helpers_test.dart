import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebrat_app/utils/community_helpers.dart';

void main() {
  group('isAllowedArchiveHost', () {
    test('allows archive.org and subdomains over https', () {
      expect(isAllowedArchiveHost(Uri.parse('https://archive.org/details/foo')), isTrue);
      expect(
          isAllowedArchiveHost(Uri.parse('https://ia801234.us.archive.org/BookReader/')), isTrue);
      expect(isAllowedArchiveHost(Uri.parse('https://s3.us.archive.org/x/y')), isTrue);
    });
    test('refuses http, other hosts, and lookalikes', () {
      expect(isAllowedArchiveHost(Uri.parse('http://archive.org/details/foo')), isFalse);
      expect(isAllowedArchiveHost(Uri.parse('https://archive.org.evil.com/x')), isFalse);
      expect(isAllowedArchiveHost(Uri.parse('https://evilarchive.org/x')), isFalse);
      expect(isAllowedArchiveHost(Uri.parse('https://example.com/x')), isFalse);
    });
  });

  group('isAllowedArchiveUrl', () {
    test('parses and validates', () {
      expect(isAllowedArchiveUrl('https://archive.org/download/foo/bar.zip'), isTrue);
      expect(isAllowedArchiveUrl('http://archive.org/download/foo'), isFalse);
      expect(isAllowedArchiveUrl('not a url %%'), isFalse);
    });
  });

  group('archiveIdFromUrl', () {
    test('takes last path segment', () {
      expect(archiveIdFromUrl('https://archive.org/details/my-book_01'), 'my-book_01');
      expect(archiveIdFromUrl('https://archive.org/download/my-book_01/file.zip'), 'file.zip');
    });
    test('rejects bad identifiers', () {
      expect(() => archiveIdFromUrl('https://archive.org'), throwsFormatException);
      expect(() => archiveIdFromUrl('https://archive.org/details/ab'), throwsFormatException);
    });
  });

  test('ratingAverage handles zero count', () {
    expect(ratingAverage(0, 0), 0.0);
    expect(ratingAverage(10, 0), 0.0);
    expect(ratingAverage(9, 2), 4.5);
  });

  test('coverSeed/coverColors are deterministic and valid', () {
    expect(coverSeed('Moby Dick'), coverSeed('Moby Dick'));
    expect(coverColors('Moby Dick').length, 2);
    expect(coverColors('Moby Dick')[0], coverColors('Moby Dick')[0]);
    expect(coverColors('Moby Dick')[1], coverColors('Moby Dick')[1]);
    // Different titles should usually differ (at least produce valid colors).
    for (final c in coverColors('Another title entirely')) {
      expect(c, isA<Color>());
    }
  });

  test('formatDuration', () {
    expect(formatDuration(0), '—');
    expect(formatDuration(-5), '—');
    expect(formatDuration(30 * 1000), '30s');
    expect(formatDuration(45 * 60 * 1000), '45m');
    expect(formatDuration((7 * 60 + 21) * 60 * 1000), '7h 21m');
    expect(formatDuration(2 * 3600 * 1000), '2h');
  });
}
