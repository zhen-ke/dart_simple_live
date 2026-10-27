import 'dart:math';

import 'package:get/get.dart';
import 'package:simple_live_shared/services/bilibili_account_service.dart';

/// 登录身份变化时把 cookie 与匿名设备号注入斗鱼站点（由宿主实现）
typedef DouyuIdentitySink = void Function(String cookie, String deviceId);

class DouyuAccountService extends GetxService {
  DouyuAccountService({
    required this.readStorage,
    required this.writeStorage,
    required this.onIdentity,
  });

  final AccountStorageReader readStorage;
  final AccountStorageWriter writeStorage;
  final DouyuIdentitySink onIdentity;

  static DouyuAccountService get instance => Get.find<DouyuAccountService>();

  var cookie = "";
  var hasCookie = false.obs;

  @override
  void onInit() {
    cookie = readStorage(AccountStorageKeys.douyuCookie);
    hasCookie.value = cookie.trim().isNotEmpty;
    setSite();
    super.onInit();
  }

  void setSite() {
    onIdentity(cookie, _ensureDeviceId());
  }

  /// 匿名身份用的本设备持久化 did：首次生成 32 位 hex 并落盘，
  /// 之后所有斗鱼请求复用，不再共用签名脚本里写死的共享 did。
  String _ensureDeviceId() {
    var stored = readStorage(AccountStorageKeys.douyuDeviceId);
    if (stored.isEmpty) {
      var random = Random.secure();
      stored =
          List.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
      writeStorage(AccountStorageKeys.douyuDeviceId, stored);
    }
    return stored;
  }

  void setCookie(String value) {
    cookie = value.trim();
    writeStorage(AccountStorageKeys.douyuCookie, cookie);
    hasCookie.value = cookie.isNotEmpty;
    setSite();
  }

  void clearCookie() => setCookie("");
}
