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
    historyBox = await Hive.openBox("History");
    followBox = await Hive.openBox("FollowUser");
    tagBox = await Hive.openBox("FollowUserTag");
    tagOrderBox = await Hive.openBox("FollowUserTagOrder");
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

  List<History> getHistores() {
    var his = historyBox.values.toList();
    his.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return his;
  }
}
