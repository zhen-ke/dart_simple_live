import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:uuid/uuid.dart';
import 'package:collection/collection.dart';

class DBService extends GetxService {
  static DBService get instance => Get.find<DBService>();
  late Box<History> historyBox;
  late Box<FollowUser> followBox;
  late Box<FollowUserTag> tagBox;

  /// 标签展示顺序：独立存储标签 id 列表，
  /// 不改动实体主键（历史版本曾用整数主键重写，导致改/删失效）
  late Box tagOrderBox;
  final Uuid uuid = const Uuid();

  Future init() async {
    // 四个 box 互不依赖，并行打开，冷启动不必串行等完四轮磁盘 IO；
    // 标签迁移只读已打开的内存数据，代价极小，必须先于关注页读取完成
    final historyFuture = Hive.openBox<History>("History");
    final followFuture = Hive.openBox<FollowUser>("FollowUser");
    final tagFuture = Hive.openBox<FollowUserTag>("FollowUserTag");
    final tagOrderFuture = Hive.openBox("FollowUserTagOrder");
    historyBox = await historyFuture;
    followBox = await followFuture;
    tagBox = await tagFuture;
    tagOrderBox = await tagOrderFuture;
    await _migrateTagKeys();
  }

  /// 迁移历史版本中被整数主键重写的标签记录：
  /// 记录迁回自身 id，原键序（即排序位置）转为顺序列表
  Future _migrateTagKeys() async {
    final misKeyed = <dynamic>[];
    for (var key in tagBox.keys) {
      final tag = tagBox.get(key);
      if (tag != null && tag.id != key) {
        misKeyed.add(key);
      }
    }
    if (misKeyed.isEmpty) return;
    final order = <String>[];
    for (var key in misKeyed) {
      final tag = tagBox.get(key)!;
      // 同 id 可能已存在由后续修改写入的更新记录：
      // 只在缺失时迁回，避免旧快照覆盖新数据
      if (!tagBox.containsKey(tag.id)) {
        await tagBox.put(tag.id, tag);
      }
      await tagBox.delete(key);
      order.add(tag.id);
    }
    await tagOrderBox.put('order', order);
  }

  // follow_user_tag 相关逻辑
  bool getFollowTagExist(String id) {
    return tagBox.containsKey(id);
  }

  // 删除标签
  Future deleteFollowTag(String id) async {
    await tagBox.delete(id);
  }

  FollowUserTag? getFollowTag(String tag) {
    return tagBox.values.firstWhereOrNull((item) => item.tag == tag);
  }

  // 判断标签名称是否重复
  bool getFollowTagExistByTag(String tag) {
    return tagBox.values.any((item) => item.tag == tag);
  }

  // 获取标签列表（按保存的顺序排列，未排序的排最后）
  List<FollowUserTag> getFollowTagList() {
    var tags = tagBox.values.toList();
    final raw = tagOrderBox.get('order');
    final order = raw is List ? raw.cast<String>() : const <String>[];
    if (order.isEmpty) return tags;
    final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
    tags.sort((a, b) =>
        (rank[a.id] ?? order.length).compareTo(rank[b.id] ?? order.length));
    return tags;
  }

  // 修改标签
  Future updateFollowTag(FollowUserTag followTag) async {
    await tagBox.put(followTag.id, followTag);
  }

  // 添加标签
  Future<FollowUserTag> addFollowTag(String tag) async {
    // 标签名唯一：已存在同名标签直接返回，不重复创建
    if (getFollowTagExistByTag(tag)) {
      return getFollowTag(tag)!;
    }
    final String uniqueId = uuid.v4();
    final followUserTag = FollowUserTag(id: uniqueId, tag: tag, userId: []);
    await tagBox.put(uniqueId, followUserTag);
    return followUserTag;
  }

  // 调整标签顺序
  Future updateFollowTagOrder(List<FollowUserTag> userTagList) async {
    // 实体主键保持不变，展示顺序独立存储
    await tagOrderBox.put('order', userTagList.map((e) => e.id).toList());
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
  // 同步合并：局域网同步、WebDAV 恢复、房间同步三条链路共用这一处实现。
  //
  // 入参一律是**已经解析完成的实体列表**，不是原始 JSON。解析在调用方完成，
  // 解析失败时根本走不到这里，因此不存在"先清空再解析、解析炸了本地数据没了"
  // 的窗口——这个 bug 在 WebDAV 恢复里真实存在过。
  //
  // [overlay] 为 true 表示云端/对端数据覆盖本地；false 表示按 id 合并。
  // ---------------------------------------------------------------------------

  /// 合并关注列表。
  /// 关注没有更新时间字段，同 id 一律以传入值为准（后写覆盖）。
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
    // 一次 putAll 落盘：逐条 await put 每条都会触发一次写入
    await followBox.putAll({for (final item in items) item.id: item});
  }

  /// 合并标签。
  /// 标签展示顺序独立存在 [tagOrderBox]，不跟随实体主键：
  /// * [ordered] 为 true 时按入参顺序重建顺序表（备份文件本身就是按序导出的）
  /// * 否则保留本地既有顺序，只裁掉已被删除的标签 id
  Future<void> mergeTags(
    List<FollowUserTag> items, {
    bool overlay = false,
    bool ordered = false,
  }) async {
    if (overlay) {
      await tagBox.clear();
    }
    if (items.isNotEmpty) {
      await tagBox.putAll({for (final item in items) item.id: item});
    }
    if (ordered) {
      await updateFollowTagOrder(items);
    } else {
      await _pruneTagOrder();
    }
  }

  /// 合并观看记录：同 id 只接受更新的 updateTime，避免旧备份回滚进度。
  Future<void> mergeHistories(
    List<History> items, {
    bool overlay = false,
  }) async {
    // 先在内存里比完新旧，再一次性落盘
    final merged = <String, History>{};
    for (final item in items) {
      if (!overlay) {
        final old = historyBox.get(item.id);
        // 本地更新时间比较新，保留本地
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

  /// 裁掉顺序表里已不存在的标签 id，保持相对顺序不变。
  Future<void> _pruneTagOrder() async {
    final raw = tagOrderBox.get('order');
    if (raw is! List) {
      return;
    }
    final alive = tagBox.keys.map((e) => e.toString()).toSet();
    final kept = raw.cast<String>().where(alive.contains).toList();
    if (kept.length != raw.length) {
      await tagOrderBox.put('order', kept);
    }
  }

  List<History> getHistores() {
    var his = historyBox.values.toList();
    his.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return his;
  }
}
