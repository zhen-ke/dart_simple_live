import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_shared/models/account/bilibili_user_info_page.dart';
import 'package:simple_live_shared/requests/http_client.dart';

/// 账号凭据的本地存取：由宿主注入自己的 LocalStorageService 实现
typedef AccountStorageReader = String Function(String key);
typedef AccountStorageWriter = void Function(String key, String value);

/// 存储键：两端取值一致（旧数据兼容），不要修改
class AccountStorageKeys {
  static const String bilibiliCookie = "BilibiliCookie";
  static const String douyinCookie = "DouyinCookie";
  static const String douyuCookie = "DouyuCookie";
  static const String douyuDeviceId = "DouyuDeviceId";
}

/// 登录身份变化时把 cookie/uid 注入对应站点实例（由宿主实现）
typedef BiliBiliIdentitySink = void Function(int uid, String cookie);

class BiliBiliAccountService extends GetxService {
  BiliBiliAccountService({
    required this.readStorage,
    required this.writeStorage,
    required this.onIdentity,
    this.onLogoutExtra,
  });

  final AccountStorageReader readStorage;
  final AccountStorageWriter writeStorage;

  /// 登录/登出后同步站点身份（BiliBiliSite.userId/cookie）
  final BiliBiliIdentitySink onIdentity;

  /// 宿主额外的登出清理（如清理 WebView Cookie），登出时 await
  final Future<void> Function()? onLogoutExtra;

  static BiliBiliAccountService get instance =>
      Get.find<BiliBiliAccountService>();

  var logined = false.obs;

  var cookie = "";
  var uid = 0;
  var name = "未登录".obs;

  @override
  void onInit() {
    cookie = readStorage(AccountStorageKeys.bilibiliCookie);
    logined.value = cookie.isNotEmpty;
    unawaited(loadUserInfo());
    super.onInit();
  }

  Future loadUserInfo() async {
    if (cookie.isEmpty) {
      return;
    }
    try {
      var result = await HttpClient.instance.getJson(
        "https://api.bilibili.com/x/member/web/account",
        header: {
          "Cookie": cookie,
        },
      );
      if (result["code"] == 0) {
        var info = BiliBiliUserInfoModel.fromJson(result["data"]);
        name.value = info.uname ?? "未登录";
        uid = info.mid ?? 0;
        onIdentity(uid, cookie);
      } else {
        unawaited(SmartDialog.showToast("哔哩哔哩登录已失效，请重新登录"));
        logout();
      }
    } catch (e) {
      unawaited(SmartDialog.showToast("获取哔哩哔哩用户信息失败，可前往账号管理重试"));
    }
  }

  void setCookie(String cookie) {
    this.cookie = cookie;
    writeStorage(AccountStorageKeys.bilibiliCookie, cookie);
    logined.value = cookie.isNotEmpty;
  }

  void logout() async {
    cookie = "";
    uid = 0;
    name.value = "未登录";
    onIdentity(uid, cookie);
    writeStorage(AccountStorageKeys.bilibiliCookie, "");
    logined.value = false;
    await onLogoutExtra?.call();
  }
}
