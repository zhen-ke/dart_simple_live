import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_shared/app/log.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_shared/models/db/follow_user.dart';
import 'package:simple_live_shared/models/db/history.dart';
import 'package:simple_live_shared/app/constant.dart';
import 'package:simple_live_tv_app/routes/app_pages.dart';
import 'package:simple_live_tv_app/routes/route_path.dart';
import 'package:simple_live_shared/services/bilibili_account_service.dart';
import 'package:simple_live_shared/services/db_service.dart';
import 'package:simple_live_shared/services/douyu_account_service.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_shared/services/local_storage_service.dart';
import 'package:simple_live_tv_app/services/sync_service.dart';

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      Log.crash(details.exception, details.stack ?? StackTrace.current);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      Log.crash(error, stack);
      return true;
    };

    try {
      await _bootstrap();
      runApp(const MyApp());
    } catch (error, stack) {
      Log.crash(error, stack);
      runApp(BootFailureApp(error: error));
    }
  }, (error, stack) => Log.crash(error, stack));
}

Future<void> _bootstrap() async {
  // 限制图片缓存数量与内存占用（最多缓存200张或50MB）。
  // TV 端封面/头像更密集且可用内存更小，不设上限时容易把内存顶高
  PaintingBinding.instance.imageCache.maximumSize = 200;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024;

  MediaKit.ensureInitialized();
  // 包信息与 Hive 初始化互不依赖，并行执行，缩短冷启动串行链
  final packageInfoReady =
      PackageInfo.fromPlatform().then(
        (info) => {
          Utils.packageInfo = info,
          Log.packageInfo = info,
        });
  await Hive.initFlutter();
  await packageInfoReady;
  //初始化服务
  await initServices();
  // 强制横屏
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeRight,
    DeviceOrientation.landscapeLeft,
  ]);
  // 全屏
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
}

/// 初始化失败时的最小可用界面。
class BootFailureApp extends StatelessWidget {
  const BootFailureApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "应用初始化失败",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                SelectableText("$error", textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future initServices() async {
  //日志信息
  // debug 全开；profile 用于性能测量必须默认静默，release 保持关闭
  CoreLog.enableLog = kDebugMode;
  CoreLog.requestLogType =
      kDebugMode ? RequestLogType.short : RequestLogType.none;
  CoreLog.onPrintLog = (level, msg) {
    switch (level) {
      case Level.debug:
        Log.d(msg);
        break;
      case Level.error:
        Log.e(msg, StackTrace.current);
        break;
      case Level.info:
        Log.i(msg);
        break;
      case Level.warning:
        Log.w(msg);
        break;
      default:
        Log.logPrint(msg);
    }
  };

  Hive.registerAdapter(FollowUserAdapter());
  Hive.registerAdapter(HistoryAdapter());

  //包信息已由 _bootstrap 与 Hive 初始化并行预取
  //本地存储与数据库互不依赖：两组 Hive box 并行打开
  Log.d("Init LocalStorage Service");
  await Future.wait([
    Get.put(LocalStorageService(
          settingsBoxName: "TVLocalStorage",
          shieldBoxName: "TVDanmuShield",
        )).init(),
    Get.put(DBService(
          historyBoxName: "TVHostiry",
          followBoxName: "TVFollowUser",
        )).init(),
  ]);
  //初始化设置控制器
  Get.put(AppSettingsController());

  // 账号服务为共享实现：凭据存取与站点注入由宿主闭包提供
  Get.put(BiliBiliAccountService(
    readStorage: (key) => LocalStorageService.instance.getValue(key, ""),
    writeStorage: (key, value) =>
        LocalStorageService.instance.setValue(key, value),
    onIdentity: (uid, cookie) {
      final site =
          Sites.allSites[Constant.kBiliBili]!.liveSite as BiliBiliSite;
      site.userId = uid;
      site.cookie = cookie;
    },
  ));

  // 斗鱼账号服务：注入登录 Cookie 与本机持久化匿名 did（共享 did 会被风控掐流）
  Get.put(DouyuAccountService(
    readStorage: (key) => LocalStorageService.instance.getValue(key, ""),
    writeStorage: (key, value) =>
        LocalStorageService.instance.setValue(key, value),
    onIdentity: (cookie, deviceId) {
      final site = Sites.allSites[Constant.kDouyu]?.liveSite;
      if (site is DouyuSite) {
        site.cookie = cookie;
        site.deviceId = deviceId;
      }
    },
  ));

  Get.put(SyncService());

  Get.put(FollowUserService());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(1920, 1080),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, child) {
        return GetMaterialApp(
          title: 'Simple Live TV',
          theme: AppStyle.lightTheme,
          initialRoute: AppSettingsController.instance.firstRun
              ? RoutePath.kAgreement
              : RoutePath.kHome,
          getPages: AppPages.routes,
          debugShowCheckedModeBanner: false,
          builder: FlutterSmartDialog.init(
            loadingBuilder: (msg) => Center(
              child: SizedBox(
                width: 64.w,
                height: 64.w,
                child: CircularProgressIndicator(
                  strokeWidth: 8.w,
                  color: Colors.white,
                ),
              ),
            ),
            //字体大小不跟随系统变化
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.0)),
              child: child!,
            ),
          ),
        );
      },
    );
  }
}
