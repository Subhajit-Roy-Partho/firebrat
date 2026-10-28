/// Groups several uploads of the same book ("editions") under one work.
/// Mirrors `community/src/works.js` so the site and the app agree on what a
/// duplicate is. Pure Dart (no Firebase imports) so it is unit-testable.
library;

/// Sort orders offered in the Community library.
enum CommunitySort {
  top('Highest rated'),
  newest('Newest'),
  most('Most ratings'),
  longest('Longest'),
  title('Title A–Z');

  const CommunitySort(this.label);
  final String label;
}

const _folds = <String, String>{
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
  'ç': 'c', 'ć': 'c', 'č': 'c',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ę': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
  'ñ': 'n', 'ń': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
  'ý': 'y', 'ÿ': 'y', 'ś': 's', 'š': 's', 'ž': 'z', 'ź': 'z', 'ż': 'z', 'ł': 'l',
};

String _fold(Object? s) {
  final lower = (s ?? '').toString().toLowerCase();
  final b = StringBuffer();
  for (final r in lower.runes) {
    final ch = String.fromCharCode(r);
    b.write(_folds[ch] ?? ch);
  }
  return b.toString();
}

/// "Frankenstein; or, The Modern Prometheus" -> "frankenstein".
String titleKey(String? title) {
  var t = _fold(title).replaceAll(RegExp(r'\([^)]*\)'), ' ');
  t = t.split(RegExp(r'\s[-–—]\s|[;:]')).first; // drop subtitles
  t = t.replaceAll(RegExp(r"['’]"), '');
  t = t.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  t = t.replaceFirst(RegExp(r'^(the|a|an) '), '');
  return t.replaceAll(' ', '-');
}

/// Surname only: "Mary Wollstonecraft Shelley" and "Shelley, Mary" -> "shelley".
String authorKey(String? author) {
  final a = _fold(author).trim();
  if (a.isEmpty) return '';
  final surname = a.contains(',') ? a.split(',').first : a.split(RegExp(r'\s+')).last;
  return surname.replaceAll(RegExp(r'[^a-z]+'), '');
}

/// Two uploads share a work when title (minus subtitle/article) and author surname match.
String workKey(Map<String, dynamic> book) {
  final t = titleKey(book['title'] as String?);
  return t.isEmpty ? '' : '$t|${authorKey(book['author'] as String?)}';
}

double avgRating(Map<String, dynamic> b) {
  final count = (b['ratingCount'] ?? 0) as num;
  return count > 0 ? ((b['ratingSum'] ?? 0) as num) / count : 0.0;
}

/// createdAt may be a Firestore Timestamp, a DateTime, a number or missing.
int createdMs(Map<String, dynamic> b) {
  final t = b['createdAt'];
  if (t == null) return 0;
  if (t is DateTime) return t.millisecondsSinceEpoch;
  if (t is num) return t.toInt();
  try {
    return (t as dynamic).millisecondsSinceEpoch as int; // Timestamp
  } catch (_) {
    return 0;
  }
}

/// Best first: higher average, then more ratings, then newer.
int compareEditions(Map<String, dynamic> a, Map<String, dynamic> b) {
  final byAvg = avgRating(b).compareTo(avgRating(a));
  if (byAvg != 0) return byAvg;
  final byCount = ((b['ratingCount'] ?? 0) as num).compareTo((a['ratingCount'] ?? 0) as num);
  if (byCount != 0) return byCount;
  return createdMs(b).compareTo(createdMs(a));
}

/// One book (title + author) and every upload of it, best-rated first.
class CommunityWork {
  CommunityWork(this.key, this.editions)
      : best = editions.first,
        title = (editions.first['title'] as String?) ?? 'Untitled',
        author = (editions.first['author'] as String?) ?? '',
        ratingCount = editions.fold<int>(0, (n, e) => n + ((e['ratingCount'] ?? 0) as num).toInt()),
        newest = editions.map(createdMs).fold<int>(0, (m, v) => v > m ? v : m),
        longest = editions
            .map((e) => ((e['totalDurationMs'] ?? 0) as num).toInt())
            .fold<int>(0, (m, v) => v > m ? v : m);

  final String key;
  final List<Map<String, dynamic>> editions;
  final Map<String, dynamic> best;
  final String title;
  final String author;
  final int ratingCount;
  final int newest;
  final int longest;
}

/// Groups [items] (each a book map that includes its document `id`) into works and
/// orders the works by [sort]. Editions inside a work are always best-rated first.
List<CommunityWork> groupWorks(List<Map<String, dynamic>> items, CommunitySort sort) {
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final b in items) {
    final k = workKey(b);
    groups.putIfAbsent(k.isEmpty ? 'id:${b['id']}' : k, () => []).add(b);
  }
  final works = [
    for (final e in groups.entries)
      CommunityWork(e.key, [...e.value]..sort(compareEditions)),
  ];
  int byTitle(CommunityWork a, CommunityWork b) =>
      a.title.toLowerCase().compareTo(b.title.toLowerCase());
  int chain(int first, int Function() next) => first != 0 ? first : next();
  works.sort((a, b) {
    switch (sort) {
      case CommunitySort.top:
        return chain(compareEditions(a.best, b.best), () => byTitle(a, b));
      case CommunitySort.newest:
        return chain(b.newest.compareTo(a.newest), () => byTitle(a, b));
      case CommunitySort.most:
        return chain(b.ratingCount.compareTo(a.ratingCount),
            () => chain(compareEditions(a.best, b.best), () => byTitle(a, b)));
      case CommunitySort.longest:
        return chain(b.longest.compareTo(a.longest), () => byTitle(a, b));
      case CommunitySort.title:
        return byTitle(a, b);
    }
  });
  return works;
}
