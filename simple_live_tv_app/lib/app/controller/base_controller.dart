import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:simple_live_tv_app/app/app_error.dart';
import 'package:simple_live_tv_app/app/base_focus_model.dart';

import 'package:flutter_easyrefresh/easy_refresh.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class BaseController extends GetxController {
  /// 加载中，更新页面
  var pageLoadding = false.obs;

  /// 加载中
  var loadding = false.obs;

  /// 空白页面
  var pageEmpty = false.obs;

  /// 页面错误
  var pageError = false.obs;

  /// 未登录
  var notLogin = false.obs;

  /// 错误信息
  var errorMsg = "".obs;

  /// 显示错误
  /// * [msg] 错误信息
  /// * [showPageError] 显示页面错误
  /// * 只在第一页加载错误时showPageError=true，后续页加载错误时使用Toast弹出通知
  void handleError(Object exception, {bool showPageError = false}) {
    var msg = exceptionToString(exception);
    if (exception is AppError && exception.notLogin) {
      notLogin.value = true;
      pageError.value = false;
      return;
    }
    if (showPageError) {
      pageError.value = true;
      errorMsg.value = msg;
    } else {
      SmartDialog.showToast(exceptionToString(msg));
    }
  }

  String exceptionToString(Object exception) {
    if (exception is AppError) {
      return exception.toString();
    }
    return exception.toString().replaceAll("Exception:", "");
  }

  void onLogin() {}
  void onLogout() {}
}

class BasePageController<T> extends BaseController {
  final ScrollController scrollController = ScrollController();
  final EasyRefreshController easyRefreshController = EasyRefreshController();
  int currentPage = 1;
  int count = 0;
  int maxPage = 0;
  int pageSize = 24;
  var canLoadMore = false.obs;
  var list = <T>[].obs;

  /// 请求代次：刷新会作废旧请求的结果，防止旧数据写回新列表
  int _requestGen = 0;

  Future refreshData() async {
    // 代次递增使在飞请求的结果被丢弃；
    // 即使上次请求还在加载，刷新也照常发起
    _requestGen++;
    currentPage = 1;
    // 必须在清空前把旧数据项交出去释放焦点节点：
    // 清空后 _loadPage 看到的已是空列表，旧节点会永久泄漏
    _disposeListItemFocusNodes(list);
    list.value = [];
    await _loadPage();
  }

  Future loadData() async {
    if (loadding.value) return;
    await _loadPage();
  }

  Future _loadPage() async {
    loadding.value = true;
    final gen = _requestGen;
    final page = currentPage;
    try {
      pageError.value = false;
      pageEmpty.value = false;
      notLogin.value = false;
      pageLoadding.value = page == 1;

      var result = await getData(page, pageSize);
      // 已被更新的请求取代：结果直接丢弃
      if (gen != _requestGen) return;

      //是否可以加载更多：返回数量不足一页即视为到底
      canLoadMore.value = result.length >= pageSize;
      if (canLoadMore.value) {
        currentPage++;
      }
      pageEmpty.value = page == 1 && result.isEmpty;
      // 赋值数据
      if (page == 1) {
        _disposeListItemFocusNodes(list);
        list.value = List<T>.from(result);
      } else {
        list.addAll(result);
      }
    } catch (e) {
      if (gen == _requestGen) {
        handleError(e, showPageError: page == 1);
      }
    } finally {
      if (gen == _requestGen) {
        loadding.value = false;
        pageLoadding.value = false;
      }
    }
  }

  /// 列表整体替换时释放旧数据项持有的焦点节点，
  /// 延后到帧末执行，确保旧 item 的 Focus 组件先完成卸载
  void _disposeListItemFocusNodes(List<T> items) {
    if (items.isEmpty) return;
    final stale = items.toList(growable: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (var item in stale) {
        if (item is FocusNodeOwner) {
          item.disposeFocusNode();
        }
      }
    });
  }

  Future<List<T>> getData(int page, int pageSize) async {
    return [];
  }

  void scrollToTopOrRefresh() {
    if (scrollController.offset > 0) {
      scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.linear,
      );
    } else {
      easyRefreshController.callRefresh();
    }
  }

  @override
  void onClose() {
    scrollController.dispose();
    easyRefreshController.dispose();
    for (var item in list) {
      if (item is FocusNodeOwner) {
        item.disposeFocusNode();
      }
    }
    super.onClose();
  }
}
