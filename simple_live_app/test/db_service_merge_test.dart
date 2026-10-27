import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_shared/models/db/history.dart';

/// DBService.merge* 的纯逻辑回归网：
/// 合并语义（后写覆盖 / 本地较新保留 / 顺序裁剪）是同步链路的数据正确性核心
void main() {
  late Directory tempDir;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('db_service_test');
    Hive.init(tempDir.path);
    Hive.registerAdapter(FollowUserAdapter());
    Hive.registerAdapter(HistoryAdapter());
    Hive.registerAdapter(FollowUserTagAdapter());
  });

  tearDownAll(() async {
    await Hive.deleteBoxFromDisk('History');
    await Hive.deleteBoxFromDisk('FollowUser');
    await Hive.deleteBoxFromDisk('FollowUserTag');
    await Hive.deleteBoxFromDisk('FollowUserTagOrder');
    await Hive.close();
    tempDir.deleteSync(recursive: true);
  });

  group('mergeFollows', () {
    test('同 id 后写覆盖，不同 id 互不影响', () async {
      final db = DBService();
      await db.init();
      await db.mergeFollows([
        FollowUser(
          id: 'bilibili_1',
          roomId: '1',
          siteId: 'bilibili',
          userName: '旧名',
          face: '',
          addTime: DateTime(2026),
        ),
        FollowUser(
          id: 'bilibili_2',
          roomId: '2',
          siteId: 'bilibili',
          userName: '二号',
          face: '',
          addTime: DateTime(2026),
        ),
      ]);
      await db.mergeFollows([
        FollowUser(
          id: 'bilibili_1',
          roomId: '1',
          siteId: 'bilibili',
          userName: '新名',
          face: '',
          addTime: DateTime(2026),
        ),
      ]);

      final list = db.getFollowList();
      expect(list, hasLength(2));
      expect(
        list.firstWhere((e) => e.id == 'bilibili_1').userName,
        '新名',
      );
      expect(
        list.firstWhere((e) => e.id == 'bilibili_2').userName,
        '二号',
      );
    });
  });

  group('mergeHistories', () {
    History history(String id, DateTime updateTime) => History(
          id: id,
          roomId: id,
          siteId: 'bilibili',
          userName: 'user',
          face: '',
          updateTime: updateTime,
        );

    test('本地观看时间较新时保留本地，远端较新时覆盖', () async {
      final db = DBService();
      await db.init();
      await db.mergeHistories([history('h1', DateTime(2026, 1, 1))]);

      // 远端更旧：本地保留
      await db.mergeHistories([history('h1', DateTime(2025, 1, 1))]);
      expect(
        db.historyBox.get('h1')!.updateTime,
        DateTime(2026, 1, 1),
      );

      // 远端更新：覆盖
      await db.mergeHistories([history('h1', DateTime(2027, 1, 1))]);
      expect(
        db.historyBox.get('h1')!.updateTime,
        DateTime(2027, 1, 1),
      );
    });

    test('overlay 先清空再写入', () async {
      final db = DBService();
      await db.init();
      await db.mergeHistories([
        history('h1', DateTime(2026, 1, 1)),
        history('h2', DateTime(2026, 1, 1)),
      ]);
      await db.mergeHistories(
        [history('h3', DateTime(2026, 1, 1))],
        overlay: true,
      );

      expect(db.historyBox.keys, hasLength(1));
      expect(db.historyBox.containsKey('h3'), isTrue);
    });
  });

  group('mergeTags', () {
    test('ordered:false 保留本地既有标签与顺序，同 id 后写覆盖', () async {
      final db = DBService();
      await db.init();
      await db.mergeTags(
        [
          FollowUserTag(id: 't1', tag: '游戏', userId: []),
          FollowUserTag(id: 't2', tag: '娱乐', userId: []),
        ],
        ordered: true,
      );

      // 远端只发来 t2：合并语义不删除本地标签，t1 仍在，仅 t2 被覆盖
      await db.mergeTags(
        [FollowUserTag(id: 't2', tag: '娱乐改名', userId: [])],
        ordered: false,
      );

      final list = db.getFollowTagList();
      expect(list.map((e) => e.id), ['t1', 't2']);
      expect(list.firstWhere((e) => e.id == 't2').tag, '娱乐改名');
    });

    test('ordered:true 按入参顺序重建顺序表', () async {
      final db = DBService();
      await db.init();
      await db.mergeTags(
        [
          FollowUserTag(id: 't2', tag: '娱乐', userId: []),
          FollowUserTag(id: 't1', tag: '游戏', userId: []),
        ],
        ordered: true,
      );

      expect(db.getFollowTagList().map((e) => e.id), ['t2', 't1']);
    });
  });
}
