import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/webdav_client.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class RemoteSyncWebDAVController extends BaseController {
  // ui
  var passwordVisible = true.obs;
  // ui-用户选择是否同步
  var isSyncFollows = true.obs;
  var isSyncHistories = true.obs;
  var isSyncBlockWord = true.obs;
  var isSyncBilibiliAccount = true.obs;

  late DAVClient davClient;
  var user = "--".obs;
  var lastRecoverTime = "--".obs;
  var lastUploadTime = "--".obs;

  final _userFollowJsonName = 'SimpleLive_follows.json';
  final _userHistoriesJsonName = 'SimpleLive_histories.json';
  final _userBlockedWordJsonName = 'SimpleLive_blocked_word.json';
  final _userBilibiliAccountJsonName = 'SimpleLive_bilibili_account.json';
  final _userSettingsJsonName = 'SimpleLive_Settings.json';
  final _userTagsJsonName = 'SimpleLive_Tags.json';

  @override
  void onInit() {
    doWebDAVInit();
    super.onInit();
  }

  // webDAV 逻辑
  // 初始化webDAV
  void doWebDAVInit() {
    var uri = LocalStorageService.instance
        .getValue(LocalStorageService.kWebDAVUri, "");
    if (uri.isEmpty) {
      notLogin.value = true;
    } else {
      user.value = LocalStorageService.instance
          .getValue(LocalStorageService.kWebDAVUser, "");
      var password = LocalStorageService.instance
          .getValue(LocalStorageService.kWebDAVPassword, "");
      davClient = DAVClient(uri, user.value, password);
      // 从未同步过默认为最新数据
      lastRecoverTime.value = Utils.parseTime(
        DateTime.fromMillisecondsSinceEpoch(
          LocalStorageService.instance.getValue(
            LocalStorageService.kWebDAVLastRecoverTime,
            DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      );
      lastUploadTime.value = Utils.parseTime(
        DateTime.fromMillisecondsSinceEpoch(
          LocalStorageService.instance.getValue(
            LocalStorageService.kWebDAVLastUploadTime,
            DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      );
      checkIsLogin();
    }
  }

  // 检查webDAV登录状态
  Future<void> checkIsLogin() async {
    try {
      // 返回登录结果
      bool value = await davClient.pingCompleter.future;
      notLogin.value = !value;
    } catch (e) {
      Log.e("$e", StackTrace.current);
      notLogin.value = true;
    }
  }

  // WebDAV登录
  void doWebDAVLogin(
      String webDAVUri, String webDAVUser, String webDAVPassword) async {
    // 确认登录
    davClient = DAVClient(webDAVUri, webDAVUser, webDAVPassword);
    await checkIsLogin();
    if (!notLogin.value) {
      // 保存到本地
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVUri, webDAVUri);
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVUser, webDAVUser);
      user.value = webDAVUser;
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVPassword, webDAVPassword);
      Get.back();
      SmartDialog.showToast("登录成功！");
    } else {
      SmartDialog.showToast("WebDAV账号密码验证失败，请重新输入！");
    }
  }

  // WebDAV登出
  @override
  Future<void> onLogout() async {
    var result = await Utils.showAlertDialog("确定要登出WebDAV账号？", title: "退出登录");
    if (result) {
      // 清除本地账号数据
      LocalStorageService.instance.setValue(LocalStorageService.kWebDAVUri, "");
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVUser, "");
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVPassword, "");
      notLogin.value = true;
    }
  }

  // webDAV上传到云端
  Future<void> doWebDAVUpload() async {
    SmartDialog.showLoading(msg: "正在上传到云端");
    try {
      final value = await _backupData();
      if (value.isEmpty) {
        SmartDialog.showToast("上传失败");
        return;
      }
      final result = await davClient.backup(Uint8List.fromList(value));
      if (!result) {
        Log.e("备份失败", StackTrace.current);
        SmartDialog.showToast("上传失败");
        return;
      }
      DateTime uploadTime = DateTime.now();
      lastUploadTime.value = Utils.parseTime(uploadTime);
      LocalStorageService.instance.setValue(
          LocalStorageService.kWebDAVLastUploadTime,
          uploadTime.millisecondsSinceEpoch);
      SmartDialog.showToast("上传成功");
    } catch (e) {
      Log.e("WebDAV上传失败：$e", StackTrace.current);
      SmartDialog.showToast("上传失败：$e");
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  // 备份所有数据
  Future<List<int>> _backupData() async {
    // Hive box 绑在主 isolate，只在这里取值；
    // jsonEncode 和 zip 压缩都是纯 CPU 活，整体丢到后台 isolate，
    // 历史几千条时不会再卡住 UI
    final payloads = <String, dynamic>{
      _userFollowJsonName: {
        'data':
            DBService.instance.getFollowList().map((e) => e.toJson()).toList(),
      },
      _userTagsJsonName: {
        'data': DBService.instance
            .getFollowTagList()
            .map((e) => e.toJson())
            .toList(),
      },
      _userHistoriesJsonName: {
        'data': DBService.instance.getHistores().map((e) => e.toJson()).toList(),
      },
      _userBlockedWordJsonName: {
        'data': AppSettingsController.instance.shieldList.toList(),
      },
      _userBilibiliAccountJsonName: {
        'data': {'cookie': BiliBiliAccountService.instance.cookie},
      },
      _userSettingsJsonName: {
        // 只备份可跨设备迁移的偏好；账号会话、WebDAV 凭据、
        // 设备号属于本机状态，不能跟着备份走。
        'data': LocalStorageService.instance.exportableSettings(),
      },
    };
    try {
      return await Isolate.run(() => _encodeBackup(payloads));
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("备份失败：$e");
      return [];
    }
  }

  // webDAV恢复到本地
  Future<void> doWebDAVRecovery() async {
    SmartDialog.showLoading(msg: "正在恢复到本地");
    try {
      final data = await davClient.recovery();
      final archive = await Isolate.run<Archive>(() {
        final zipDecoder = ZipDecoder();
        return zipDecoder.decodeBytes(data);
      });
      for (ArchiveFile file in archive) {
        await _recovery(file);
      }
      SmartDialog.showToast('同步完成');
      DateTime recoverTime = DateTime.now();
      lastRecoverTime.value = Utils.parseTime(recoverTime);
      LocalStorageService.instance.setValue(
          LocalStorageService.kWebDAVLastRecoverTime,
          recoverTime.millisecondsSinceEpoch);
    } catch (e) {
      Log.e("WebDAV恢复失败：$e", StackTrace.current);
      SmartDialog.showToast("恢复失败：$e");
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  Future<void> _recovery(ArchiveFile file) async {
    if (file.isFile && file.name.endsWith('.json')) {
      var jsonString = utf8.decode(file.content);
      var jsonData = json.decode(jsonString)['data'];
      // 同步follows
      if (file.name == _userFollowJsonName && isSyncFollows.value) {
        // 当前云优先
        try {
          // 先解析再交给 DBService 覆盖：解析失败时本地数据保持原样
          final users = (jsonData as List)
              .map((item) => FollowUser.fromJson(item))
              .toList();
          await DBService.instance.mergeFollows(users, overlay: true);
          Log.i('已同步关注用户列表');
        } catch (e) {
          Log.e('同步关注用户列表失败: $e', StackTrace.current);
        }
      } else if (file.name == _userHistoriesJsonName && isSyncHistories.value) {
        try {
          final histories = (jsonData as List)
              .map((item) => History.fromJson(item))
              .toList();
          await DBService.instance.mergeHistories(histories);
          Log.i('已同步用户观看历史记录');
        } catch (e) {
          Log.e('同步用户观看历史记录失败: $e', StackTrace.current);
        }
      } else if (file.name == _userBlockedWordJsonName &&
          isSyncBlockWord.value) {
        try {
          for (var keyword in jsonData) {
            AppSettingsController.instance.addShieldList(keyword.trim());
          }
          Log.i('已同步用户屏蔽词');
        } catch (e) {
          Log.e('同步用户屏蔽词失败:$e', StackTrace.current);
        }
      } else if (file.name == _userBilibiliAccountJsonName &&
          isSyncBilibiliAccount.value) {
        try {
          var cookie = jsonData['cookie'];
          BiliBiliAccountService.instance.setCookie(cookie);
          BiliBiliAccountService.instance.loadUserInfo();
          Log.i('已同步哔哩哔哩账号');
        } catch (e) {
          Log.e('同步哔哩哔哩账号失败：$e', StackTrace.current);
        }
      } else if (file.name == _userSettingsJsonName) {
        try {
          await LocalStorageService.instance.restoreSettings(
            Map<String, dynamic>.from(jsonData as Map),
          );
          // 恢复后立即把内存中的设置同步到刚写入的值，
          // 否则界面仍显示旧设置，下一次写入还会把旧值写回去。
          AppSettingsController.instance.reload();
          AppSettingsController.instance.applyTheme();
          Log.i('已同步用户设置');
        } catch (e) {
          Log.e("同步用户设置失败：$e", StackTrace.current);
        }
      } else if (file.name == _userTagsJsonName && isSyncFollows.value) {
        try {
          // 标签功能和关注具有依赖关系，必须同时同步。
          // 备份文件是按展示顺序导出的，恢复时据此重建顺序表，
          // 否则标签顺序会退回 Hive 的键序（历史版本丢过顺序）
          final tags = (jsonData as List)
              .map((item) => FollowUserTag.fromJson(item))
              .toList();
          await DBService.instance.mergeTags(
            tags,
            overlay: true,
            ordered: true,
          );
          EventBus.instance.emit(Constant.kUpdateFollow, 0);
          Log.i('已同步用户自定义标签');
        } catch (e) {
          Log.e('同步用户自定义标签失败:$e', StackTrace.current);
        }
      } else {
        return;
      }
    } else {
      Log.i('不是正确的文件名');
    }
  }

  // ui控制--密码可见控制
  void changePasswordVisible() {
    passwordVisible.value = !passwordVisible.value;
  }

  void changeIsSyncFollows() {
    isSyncFollows.value = !isSyncFollows.value;
  }

  void changeIsSyncHistories() {
    isSyncHistories.value = !isSyncHistories.value;
  }

  void changeIsSyncBlockWord() {
    isSyncBlockWord.value = !isSyncBlockWord.value;
  }

  void changeIsSyncBilibiliAccount() {
    isSyncBilibiliAccount.value = !isSyncBilibiliAccount.value;
  }
}

/// 在后台 isolate 里把各份数据编码成 json 再打成一个 zip。
/// 直接按文件名写进 archive，省掉原来「写临时文件 → 再读回来」的一轮磁盘 IO。
List<int> _encodeBackup(Map<String, dynamic> payloads) {
  final archive = Archive();
  for (final entry in payloads.entries) {
    final bytes = utf8.encode(jsonEncode(entry.value));
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}
