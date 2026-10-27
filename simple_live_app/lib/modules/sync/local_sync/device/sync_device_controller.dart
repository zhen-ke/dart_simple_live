import 'dart:convert';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_shared/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'package:simple_live_app/requests/sync_client_request.dart';
import 'package:simple_live_shared/services/bilibili_account_service.dart';
import 'package:simple_live_shared/services/db_service.dart';
import 'package:simple_live_app/services/sync_service.dart';

class SyncDeviceController extends BaseController {
  final SyncClinet client;
  final SyncClientInfoModel info;
  SyncDeviceController({required this.client, required this.info});
  SyncClientRequest request = SyncClientRequest();

  Future<bool> showOverlayDialog() async {
    var overlay = await Utils.showAlertDialog(
      "是否覆盖远端数据？",
      title: "数据覆盖",
      confirm: "覆盖",
      cancel: "不覆盖",
    );
    return overlay;
  }

  void syncFollowAndTag() async {
    try {
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "同步中...");
      var users = DBService.instance.getFollowList();
      var tags = DBService.instance.getFollowTagList();
      var data = await Utils.encodeJsonInIsolate(
          users.map((e) => e.toJson()).toList());
      var dataT = await Utils.encodeJsonInIsolate(
          tags.map((e) => e.toJson()).toList());
      await request.syncFollow(client, data, overlay: overlay);
      // 标签和关注必须同时同步
      await request.syncTag(client, dataT, overlay: overlay);
      SmartDialog.showToast("已同步关注列表和标签");
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncHistory() async {
    try {
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "同步中...");
      var histores = DBService.instance.getHistores();
      var data = await Utils.encodeJsonInIsolate(
          histores.map((e) => e.toJson()).toList());
      await request.syncHistory(client, data, overlay: overlay);
      SmartDialog.showToast("已同步历史记录");
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBlockedWord() async {
    try {
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "同步中...");
      var shieldList = AppSettingsController.instance.shieldList;
      var data = await Utils.encodeJsonInIsolate(shieldList.toList());
      await request.syncBlockedWord(client, data, overlay: overlay);
      SmartDialog.showToast("已同步屏蔽词");
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBiliAccount() async {
    try {
      if (!BiliBiliAccountService.instance.logined.value) {
        SmartDialog.showToast("未登录哔哩哔哩");
        return;
      }
      // 账号凭据是敏感数据且链路为明文 HTTP：发送前明确告知风险
      var confirmed = await Utils.showAlertDialog(
        "登录凭据将通过局域网明文传输，仅建议在可信网络内使用。是否继续？",
        title: "同步账号",
        confirm: "继续",
        cancel: "取消",
      );
      if (!confirmed) {
        return;
      }
      SmartDialog.showLoading(msg: "同步中...");

      await request.syncBiliAccount(
          client, BiliBiliAccountService.instance.cookie);
      SmartDialog.showToast("已同步哔哩哔哩账号");
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }
}
