import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';
import 'package:simple_live_tv_app/services/douyu_account_service.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class SettingsController extends BaseController
    with GetTickerProviderStateMixin {
  late TabController tabController;
  var tabIndex = 0.obs;

  SettingsController() {
    tabController = TabController(length: 5, vsync: this);
    tabController.animation?.addListener(() {
      var currentIndex = (tabController.animation?.value ?? 0).round();
      if (tabIndex.value == currentIndex) {
        return;
      }
      tabIndex.value = currentIndex;
      if (tabIndex.value == 0) {
        hardwareDecodeFocusNode.requestFocus();
      }
      if (tabIndex.value == 1) {
        danmakuFoucsNode.requestFocus();
      }
      if (tabIndex.value == 2) {
        autoUpdateFollowEnableFocusNode.requestFocus();
      }
      if (tabIndex.value == 3) {
        bilibiliFoucsNode.requestFocus();
      }
      if (tabIndex.value == 4) {
        versionFocusNode.requestFocus();
      }
    });
  }
  var hardwareDecodeFocusNode = AppFocusNode()..isFoucsed.value = true;
  var compatibleModeFocusNode = AppFocusNode();
  var scaleFoucsNode = AppFocusNode();
  var defaultQualityFocusNode = AppFocusNode();
  var danmakuFoucsNode = AppFocusNode();
  var danmakuSizeFoucsNode = AppFocusNode();
  var danmakuSpeedFoucsNode = AppFocusNode();
  var danmakuAreaFoucsNode = AppFocusNode();
  var danmakuOpacityFoucsNode = AppFocusNode();
  var danmakuStorkeFoucsNode = AppFocusNode();

  var autoUpdateFollowEnableFocusNode = AppFocusNode();
  var autoUpdateFollowDurationFocusNode = AppFocusNode();
  var updateFollowThreadFocusNode = AppFocusNode();

  var bilibiliFoucsNode = AppFocusNode();
  var douyuFoucsNode = AppFocusNode();
  var versionFocusNode = AppFocusNode();

  /// 页面销毁时释放控制器持有的全部焦点节点，避免离场后仍被 Focus 树引用
  @override
  void onClose() {
    tabController.dispose();
    for (final node in [
      hardwareDecodeFocusNode,
      compatibleModeFocusNode,
      scaleFoucsNode,
      defaultQualityFocusNode,
      danmakuFoucsNode,
      danmakuSizeFoucsNode,
      danmakuSpeedFoucsNode,
      danmakuAreaFoucsNode,
      danmakuOpacityFoucsNode,
      danmakuStorkeFoucsNode,
      autoUpdateFollowEnableFocusNode,
      autoUpdateFollowDurationFocusNode,
      updateFollowThreadFocusNode,
      bilibiliFoucsNode,
      douyuFoucsNode,
      versionFocusNode,
    ]) {
      node.dispose();
    }
    super.onClose();
  }

  void bilibiliTap() async {
    if (BiliBiliAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出哔哩哔哩账号吗？", title: "退出登录");
      if (result) {
        BiliBiliAccountService.instance.logout();
      }
    } else {
      AppNavigator.toBiliBiliLogin();
    }
  }

  void douyuTap() async {
    final account = DouyuAccountService.instance;
    final value = await Utils.showEditTextDialog(
      account.cookie,
      title: "斗鱼 Cookie",
      hintText: "粘贴已登录 www.douyu.com 的完整 Cookie，留空使用匿名播放",
    );
    if (value == null) {
      return;
    }
    final cookie = value.replaceAll(RegExp(r'[\r\n\t]'), '').trim();
    account.setCookie(cookie);
    SmartDialog.showToast(
      account.hasCookie.value ? "斗鱼 Cookie 已保存" : "已清除斗鱼 Cookie，将使用匿名播放",
    );
    update();
  }

}
