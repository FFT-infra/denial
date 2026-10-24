import 'package:denial_flutter_sdk/applications.dart';
import 'package:flutter_test/flutter_test.dart';

DesktopApp _app(String id) => DesktopApp(
  id: id,
  name: id,
  exec: id,
  desktopPath: '/usr/share/applications/$id.desktop',
  categories: const <String>[],
);

HomeGridItem _item(String id) => HomeGridItem.app(_app(id));

List<String?> _ids(List<HomeGridItem?> slots) => [
  for (final item in slots) item?.id,
];

void main() {
  const pageSize = 16;

  setUp(() => HomeGridLayout.columns = 4);

  group('folders', () {
    test('an app dropped on an app makes a folder in the target cell', () {
      final slots = [_item('a'), null, _item('b')];
      final next = HomeGridLayout.merge(
        slots,
        0,
        2,
        folderId: 'folder:x',
        folderName: 'Games',
      )!;
      expect(next[0], isNull);
      final folder = next[2]!;
      expect(folder.isFolder, isTrue);
      expect(folder.folderName, 'Games');
      expect(folder.folderApps.map((item) => item.id), ['app:b', 'app:a']);
    });

    test('an app dropped on a folder joins it at the end', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b')],
      );
      final next = HomeGridLayout.merge(
        [folder, _item('c')],
        1,
        0,
        folderId: 'folder:unused',
        folderName: 'unused',
      )!;
      expect(next[1], isNull);
      expect(next[0]!.id, 'folder:x');
      expect(next[0]!.folderApps.map((item) => item.id), [
        'app:a',
        'app:b',
        'app:c',
      ]);
    });

    test('widgets and folders never merge into anything', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b')],
      );
      final slots = [HomeGridItem.clock(), null, _item('c'), folder];
      expect(HomeGridLayout.canMerge(slots, 0, 2), isFalse);
      expect(HomeGridLayout.canMerge(slots, 3, 2), isFalse);
      expect(HomeGridLayout.canMerge(slots, 2, 0), isFalse);
      expect(HomeGridLayout.canMerge(slots, 2, 3), isTrue);
    });

    test('a folder left with one app becomes that app', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b')],
      );
      final next = HomeGridLayout.moveOutOfFolder(
        [folder],
        0,
        'app:a',
        5,
        pageSize,
      )!;
      expect(_ids(next), ['app:b', null, null, null, null, 'app:a']);
    });

    test('an app moved out of a folder takes the nearest free cell', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b'), _item('c')],
      );
      final next = HomeGridLayout.moveOutOfFolder(
        [folder, _item('d'), null],
        0,
        'app:c',
        1,
        pageSize,
      )!;
      expect(_ids(next), ['folder:x', 'app:d', 'app:c']);
      expect(next[0]!.folderApps.length, 2);
    });

    test('an app moves from one folder into another', () {
      final first = HomeGridItem.folder(
        id: 'folder:1',
        name: 'One',
        apps: [_item('a'), _item('b'), _item('c')],
      );
      final second = HomeGridItem.folder(
        id: 'folder:2',
        name: 'Two',
        apps: [_item('d'), _item('e')],
      );
      final next = HomeGridLayout.moveFromFolderInto(
        [first, second],
        0,
        'app:a',
        1,
        folderId: 'folder:3',
        folderName: 'Three',
      )!;
      expect(next[0]!.folderApps.map((item) => item.id), ['app:b', 'app:c']);
      expect(next[1]!.folderApps.map((item) => item.id), [
        'app:d',
        'app:e',
        'app:a',
      ]);
    });

    test('reordering keeps every app', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b'), _item('c')],
      );
      final next = HomeGridLayout.reorderFolder([folder], 0, 'app:a', 2)!;
      expect(next[0]!.folderApps.map((item) => item.id), [
        'app:b',
        'app:c',
        'app:a',
      ]);
    });

    test('folder contents count as grid applications', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b')],
      );
      expect(
        HomeGridLayout.appsIn([HomeGridItem.clock(), folder, null, _item('c')])
            .map((item) => item.id),
        ['app:a', 'app:b', 'app:c'],
      );
    });
  });

  group('saved layouts', () {
    test('restore folders, drop missing apps and dissolve a lone app', () {
      final slots = HomeGridLayout.initialSlotsForApps(
        [_app('a'), _app('b'), _app('c'), _app('d')],
        const [],
        const [
          HomeLayoutSlot(id: 'widget:clock', colSpan: 2, rowSpan: 1),
          null,
          HomeLayoutSlot(
            id: 'folder:x',
            name: 'Tools',
            children: ['app:a', 'app:b'],
          ),
          HomeLayoutSlot(
            id: 'folder:y',
            name: 'Gone',
            children: ['app:c', 'app:uninstalled'],
          ),
        ],
      );
      expect(_ids(slots), ['widget:clock', null, 'folder:x', 'app:c', 'app:d']);
      expect(slots[2]!.folderName, 'Tools');
    });

    test('a refresh removes uninstalled apps from folders', () {
      final folder = HomeGridItem.folder(
        id: 'folder:x',
        name: 'Tools',
        apps: [_item('a'), _item('b'), _item('c')],
      );
      final slots = HomeGridLayout.refreshSlotsForApps(
        [folder],
        [_app('a'), _app('c')],
        const [],
      );
      expect(slots.single!.folderApps.map((item) => item.id), [
        'app:a',
        'app:c',
      ]);
    });
  });

  group('resizing', () {
    test('a widget grows leftward by moving its anchor', () {
      final slots = [null, HomeGridItem.clock()];
      final next = HomeGridLayout.resizeSlot(slots, 1, 0, 3, 1, pageSize)!;
      expect(next[1], isNull);
      expect(next[0]!.colSpan, 3);
    });

    test('a widget cannot grow over another item or off its page', () {
      final slots = [_item('a'), HomeGridItem.clock()];
      expect(
        HomeGridLayout.canResizeSlot(slots, 1, 0, 3, 1, pageSize),
        isFalse,
      );
      expect(HomeGridLayout.canResizeSlot(slots, 1, 1, 3, 1, pageSize), isTrue);
      expect(
        HomeGridLayout.canResizeSlot(slots, 1, 1, 3, 4, pageSize),
        isFalse,
      );
    });
  });
}
