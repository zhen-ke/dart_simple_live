import 'package:get/get.dart';
import 'package:simple_live_shared/services/bilibili_account_service.dart';

/// 登录身份变化时把 cookie 注入抖音站点（由宿主实现）
typedef DouyinIdentitySink = void Function(String cookie);

class DouyinAccountService extends GetxService {
  DouyinAccountService({
    required this.readStorage,
    required this.writeStorage,
    required this.onIdentity,
  });

  final AccountStorageReader readStorage;
  final AccountStorageWriter writeStorage;
  final DouyinIdentitySink onIdentity;

  static DouyinAccountService get instance => Get.find<DouyinAccountService>();

  var cookie = "";
  var hasCookie = false.obs;

  @override
  void onInit() {
    cookie = readStorage(AccountStorageKeys.douyinCookie);
    hasCookie.value = cookie.isNotEmpty;
    onIdentity(cookie);
    super.onInit();
  }

  void setCookie(String cookie) {
    this.cookie = cookie;
    writeStorage(AccountStorageKeys.douyinCookie, cookie);
    hasCookie.value = cookie.isNotEmpty;
    onIdentity(cookie);
  }

  void clearCookie() {
    cookie = "";
    writeStorage(AccountStorageKeys.douyinCookie, "");
    hasCookie.value = false;
    onIdentity(cookie);
  }
}
