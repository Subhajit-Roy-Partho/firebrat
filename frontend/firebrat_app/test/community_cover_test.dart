import 'package:firebrat_app/widgets/community_detail_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('communityCoverUrl points at the package cover.jpg', () {
    expect(
      communityCoverUrl({'archiveId': 'firebrat-alice', 'packageKind': 'zip', 'packageFile': 'firebrat-alice.zip'}),
      'https://archive.org/download/firebrat-alice/firebrat-alice.zip/cover.jpg',
    );
    expect(communityCoverUrl({'archiveId': 'some-item', 'packageKind': 'folder'}),
        'https://archive.org/download/some-item/cover.jpg');
    expect(communityCoverUrl({}), isNull);
    expect(communityCoverUrl({'archiveId': 'bad id!'}), isNull);
  });
}
