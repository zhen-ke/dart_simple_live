import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';

import 'package:simple_live_shared/models/db/history.dart';

class DBService extends GetxService {
  static DBService get instance => Get.find<DBService>();
  late Box<History> historyBox;
  late Box<FollowUser> followBox;

  Future init() async {
    // 两个 box 互不依赖，并行打开
    final historyFuture = Hive.openBox<History>("TVHostiry");
    final followFuture = Hive.openBox<FollowUser>("TVFollowUser");
    historyBox = await historyFuture;
    followBox = await followFuture;
  }

  bool getFollowExist(String id) {
    return followBox.containsKey(id);
  }

  List<FollowUser> getFollowList() {
    return followBox.values.toList();
  }

  Future addFollow(FollowUser follow) async {
    await followBox.put(follow.id, follow);
  }

  Future deleteFollow(String id) async {
    await followBox.delete(id);
  }

  History? getHistory(String id) {
    if (historyBox.containsKey(id)) {
      return historyBox.get(id);
    }
    return null;
  }

  Future addOrUpdateHistory(History history) async {
    await historyBox.put(history.id, history);
  }

  // ---------------------------------------------------------------------------
  // 同步合并：与 app 端保持同一套语义（详见 simple_live_app 的 DBService）。
  // 入参是已解析完成的实体列表，解析失败走不到这里，
  // 不存在"先清空再解析、解析炸了本地数据没了"的窗口。
  // ---------------------------------------------------------------------------

  /// 合并关注列表。[overlay] 为 true 表示对端数据覆盖本地。
  Future<void> mergeFollows(
    List<FollowUser> items, {
    bool overlay = false,
  }) async {
    if (overlay) {
      await followBox.clear();
    }
    if (items.isEmpty) {
      return;
    }
    await followBox.putAll({for (final item in items) item.id: item});
  }

  /// 合并观看记录：同 id 只接受更新的 updateTime，避免旧数据回滚进度。
  Future<void> mergeHistories(
    List<History> items, {
    bool overlay = false,
  }) async {
    final merged = <String, History>{};
    for (final item in items) {
      if (!overlay) {
        final old = historyBox.get(item.id);
        if (old is History && old.updateTime.isAfter(item.updateTime)) {
          continue;
        }
      }
      merged[item.id] = item;
    }
    if (overlay) {
      await historyBox.clear();
    }
    if (merged.isNotEmpty) {
      await historyBox.putAll(merged);
    }
  }

  List<History> getHistores() {
    var his = historyBox.values.toList();
    his.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return his;
  }
}
