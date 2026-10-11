import 'dart:math';

import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class DouyuAccountService extends GetxService {
  static DouyuAccountService get instance => Get.find<DouyuAccountService>();

  var cookie = "";
  var hasCookie = false.obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuCookie, "");
    hasCookie.value = cookie.trim().isNotEmpty;
    setSite();
    super.onInit();
  }

  void setSite() {
    var site = Sites.allSites[Constant.kDouyu]?.liveSite;
    if (site is DouyuSite) {
      site.cookie = cookie;
      site.deviceId = _ensureDeviceId();
    }
  }

  /// 匿名身份用的本设备持久化 did：首次生成 32 位 hex 并落盘，
  /// 之后所有斗鱼请求复用，不再共用签名脚本里写死的共享 did。
  String _ensureDeviceId() {
    var stored = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuDeviceId, "");
    if (stored.isEmpty) {
      var random = Random.secure();
      stored =
          List.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
      LocalStorageService.instance
          .setValue(LocalStorageService.kDouyuDeviceId, stored);
    }
    return stored;
  }

  void setCookie(String value) {
    cookie = value.trim();
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuCookie, cookie);
    hasCookie.value = cookie.isNotEmpty;
    setSite();
  }

  void clearCookie() => setCookie("");
}
