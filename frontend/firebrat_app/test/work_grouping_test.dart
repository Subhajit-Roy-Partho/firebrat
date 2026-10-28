import 'package:firebrat_app/utils/work_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> b(String id, String title, String author,
        {num sum = 0, num count = 0, int created = 0, int dur = 0}) =>
    {
      'id': id,
      'title': title,
      'author': author,
      'ratingSum': sum,
      'ratingCount': count,
      'createdAt': created,
      'totalDurationMs': dur,
    };

void main() {
  test('titleKey drops subtitles, articles, apostrophes, diacritics', () {
    expect(titleKey('Frankenstein; or, The Modern Prometheus'), 'frankenstein');
    expect(titleKey('The Time Machine'), 'time-machine');
    expect(titleKey("Alice's Adventures in Wonderland"), 'alices-adventures-in-wonderland');
    expect(titleKey('Alice’s Adventures in Wonderland'), 'alices-adventures-in-wonderland');
    expect(titleKey('Les Misérables (Volume 1)'), 'les-miserables');
    expect(titleKey('Dracula - Complete'), 'dracula');
    expect(titleKey(''), '');
  });

  test('authorKey uses the surname for any name order', () {
    expect(authorKey('Mary Wollstonecraft Shelley'), 'shelley');
    expect(authorKey('Shelley, Mary'), 'shelley');
    expect(authorKey('L. M. Montgomery'), 'montgomery');
    expect(authorKey('Charlotte Brontë'), 'bronte');
    expect(authorKey(null), '');
  });

  test('same work shares a key; different authors do not', () {
    expect(workKey(b('1', 'Frankenstein', 'Mary Shelley')),
        workKey(b('2', 'Frankenstein; or, The Modern Prometheus', 'Shelley, Mary W.')));
    expect(workKey(b('1', 'Emma', 'Jane Austen')), isNot(workKey(b('2', 'Emma', 'Someone Else'))));
  });

  test('editions are best-rated first (avg, then count, then newest)', () {
    final works = groupWorks([
      b('a', 'Dracula', 'Bram Stoker', sum: 8, count: 2, created: 1),
      b('b', 'Dracula', 'Bram Stoker', sum: 5, count: 1, created: 2),
      b('c', 'Dracula', 'Bram Stoker', sum: 20, count: 5, created: 3),
      b('d', 'Dracula', 'Bram Stoker', created: 9),
    ], CommunitySort.top);
    expect(works, hasLength(1));
    expect(works.first.editions.map((e) => e['id']), ['b', 'c', 'a', 'd']);
    expect(works.first.ratingCount, 8);
  });

  test('works follow the chosen sort', () {
    final items = [
      b('1', 'Zeta', 'A One', sum: 5, count: 1, created: 100, dur: 5000),
      b('2', 'Alpha', 'B Two', sum: 8, count: 2, created: 300, dur: 9000),
      b('3', 'Mid', 'C Three', sum: 30, count: 10, created: 200, dur: 1000),
    ];
    List<String> ids(CommunitySort s) =>
        groupWorks(items, s).map((w) => w.best['id'] as String).toList();
    expect(ids(CommunitySort.top), ['1', '2', '3']);
    expect(ids(CommunitySort.newest), ['2', '3', '1']);
    expect(ids(CommunitySort.most), ['3', '2', '1']);
    expect(ids(CommunitySort.longest), ['2', '1', '3']);
    expect(ids(CommunitySort.title), ['2', '3', '1']);
  });

  test('untitled books stay separate and avgRating handles zero', () {
    final works = groupWorks([b('3', '', ''), b('4', '', '')], CommunitySort.newest);
    expect(works, hasLength(2));
    expect(avgRating(b('x', 't', 'a')), 0);
  });
}
