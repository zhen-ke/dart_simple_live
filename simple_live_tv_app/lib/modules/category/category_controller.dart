import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/base_focus_model.dart';
import 'package:simple_live_shared/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/sites.dart';

class CategoryController extends BasePageController<AppLiveCategory> {
  var siteId = Constant.kBiliBili.obs;
  var site = Sites.allSites[Constant.kBiliBili]!;

  @override
  void onInit() {
    refreshData();
    super.onInit();
  }

  void setSite(String id) {
    siteId.value = id;
    site = Sites.allSites[id]!;
    refreshData();
  }

  @override
  Future<List<AppLiveCategory>> getData(int page, int pageSize) async {
    var result = await site.liveSite.getCategores();

    return result.map((e) => AppLiveCategory.fromLiveCategory(e)).toList();
  }
}

class AppLiveCategory extends LiveCategory implements FocusNodeOwner {
  var showAll = false.obs;
  final List<LiveSubCategoryExt> childrenExt;
  AppLiveCategory({
    required super.id,
    required super.name,
    required super.children,
  }) : childrenExt = children
            .map((e) => LiveSubCategoryExt(
                  id: e.id,
                  name: e.name,
                  parentId: e.parentId,
                  pic: e.pic,
                ))
            .toList() {
    showAll.value = children.length < 19;
  }

  List<LiveSubCategoryExt> get take15 => childrenExt.take(15).toList();

  AppFocusNode moreFocusNode = AppFocusNode();
  bool _focusNodesDisposed = false;

  /// 类目被替换时连同子类目的焦点节点一起释放（子项不在分页列表里，需父项代管）
  @override
  void disposeFocusNode() {
    if (_focusNodesDisposed) return;
    _focusNodesDisposed = true;
    moreFocusNode.dispose();
    for (final child in childrenExt) {
      child.disposeFocusNode();
    }
  }

  factory AppLiveCategory.fromLiveCategory(LiveCategory item) {
    return AppLiveCategory(
      children: item.children,
      id: item.id,
      name: item.name,
    );
  }
}

class LiveSubCategoryExt extends LiveSubCategory with BaseFocusModel {
  LiveSubCategoryExt({
    required super.id,
    required super.name,
    required super.parentId,
    super.pic,
  });
}
