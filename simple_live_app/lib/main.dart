import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_shared/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/utils/listen_fourth_button.dart';
import 'package:simple_live_shared/app/constant.dart';
import 'package:simple_live_shared/models/db/follow_user.dart';
import 'package:simple_live_shared/models/db/follow_user_tag.dart';
import 'package:simple_live_shared/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/other/debug_log_page.dart';
import 'package:simple_live_app/routes/app_pages.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_shared/services/bilibili_account_service.dart';
import 'package:simple_live_shared/services/douyin_account_service.dart';
import 'package:simple_live_shared/services/db_service.dart';
import 'package:simple_live_shared/services/douyu_account_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_shared/services/local_storage_service.dart';
import 'package:simple_live_shared/services/sync_service.dart';
import 'package:simple_live_app/services/system_control_service.dart';
import 'package:simple_live_app/widgets/status/app_loadding_widget.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:window_manager/window_manager.dart';

import 'package:path/path.dart' as p;
import 'package:dynamic_color/dynamic_color.dart';

void main() {
  runZonedGuarded(
    () async {
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
    },
    (error, stack) => Log.crash(error, stack),
  );
}

Future<void> _bootstrap() async {
  // 限制图片缓存数量与内存占用（最多缓存200张或50MB），缓解因大量主播头像等引发的高内存问题
  PaintingBinding.instance.imageCache.maximumSize = 200;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024;

  MediaKit.ensureInitialized();

  // 窗口初始化、包信息读取与数据迁移互不依赖：并行执行，
  // 冷启动不必串行等完三个平台调用
  final windowReady = initWindow();
  final packageInfoReady =
      PackageInfo.fromPlatform().then(
        (info) => {
          Utils.packageInfo = info,
          Log.packageInfo = info,
        });

  // 迁移必须在 Hive 打开任何 box 之前完成：
  // 桌面端要把旧目录的 hive 文件搬进 Application Support
  await migrateData();
  await Hive.initFlutter(
    (!Platform.isAndroid && !Platform.isIOS)
        ? (await getApplicationSupportDirectory()).path
        : null,
  );

  // 包信息就绪是服务初始化的前置条件（设置控制器等会读取版本号）
  await Future.wait([windowReady, packageInfoReady]);
  //初始化服务
  await initServices();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  //设置状态栏为透明
  SystemUiOverlayStyle systemUiOverlayStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
  );
  SystemChrome.setSystemUIOverlayStyle(systemUiOverlayStyle);
}

/// 将Hive数据迁移到Application Support
Future migrateData() async {
  if (Platform.isAndroid || Platform.isIOS) {
    return;
  }
  var hiveFileList = [
    "followuser",
    //旧版本写错成hostiry了
    "hostiry",
    "followusertag",
    "localstorage",
    "danmushield",
  ];
  try {
    var newDir = await getApplicationSupportDirectory();
    var hiveFile = File(p.join(newDir.path, "followuser.hive"));
    if (await hiveFile.exists()) {
      return;
    }

    var oldDir = await getApplicationDocumentsDirectory();
    for (var element in hiveFileList) {
      var oldFile = File(p.join(oldDir.path, "$element.hive"));
      if (await oldFile.exists()) {
        var fileName = "$element.hive";
        if (element == "hostiry") {
          fileName = "history.hive";
        }
        await oldFile.copy(p.join(newDir.path, fileName));
        await oldFile.delete();
      }
      var lockFile = File(p.join(oldDir.path, "$element.lock"));
      if (await lockFile.exists()) {
        await lockFile.delete();
      }
    }
  } catch (e) {
    Log.logPrint(e);
  }
}

Future initWindow() async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    size: Size(1200, 800),
    minimumSize: Size(280, 280),
    center: true,
    title: "Simple Live",
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

Future initServices() async {
  Hive.registerAdapter(FollowUserAdapter());
  Hive.registerAdapter(HistoryAdapter());
  Hive.registerAdapter(FollowUserTagAdapter());

  //包信息已由 _bootstrap 与数据迁移并行预取
  //本地存储与数据库互不依赖：两组 Hive box 并行打开，
  //不再让 6 次 box 打开排成一条串行磁盘 IO 链
  Log.d("Init LocalStorage Service");
  await Future.wait([
    Get.put(LocalStorageService()).init(),
    Get.put(DBService()).init(),
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
    onLogoutExtra: () async {
      // 移动端登出时同步清理 WebView 内的站点 Cookie
      if (Platform.isAndroid || Platform.isIOS) {
        await CookieManager.instance().deleteAllCookies();
      }
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

  Get.put(DouyinAccountService(
    readStorage: (key) => LocalStorageService.instance.getValue(key, ""),
    writeStorage: (key, value) =>
        LocalStorageService.instance.setValue(key, value),
    onIdentity: (cookie) {
      (Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite).cookie =
          cookie;
    },
  ));

  // 同步服务为共享实现：平台标识、设备名兜底、屏蔽词落点与确认弹窗由宿主提供
  Get.put(SyncService(
    platformType: Platform.operatingSystem,
    defaultDeviceName: "SimpleLive-${Platform.operatingSystem}",
    onAddShieldWord: (word) =>
        AppSettingsController.instance.addShieldList(word),
    onClearShieldWords: () async {
      await AppSettingsController.instance.clearShieldList();
    },
    confirmDialog: (content, title, confirm, cancel) =>
        Utils.showAlertDialog(
      content,
      title: title,
      confirm: confirm,
      cancel: cancel,
    ),
  ));

  Get.put(FollowService());

  Get.put(SystemControlService());

  initCoreLog();
}

void initCoreLog() {
  //日志信息
  // debug 全开；profile 用于性能测量必须默认静默；
  // release 仅在用户开启"日志记录"后打开，HTTP 日志随之启停
  final logEnabled =
      kDebugMode || AppSettingsController.instance.logEnable.value;
  CoreLog.enableLog = logEnabled;
  Log.enabled = logEnabled;
  CoreLog.requestLogType =
      logEnabled ? RequestLogType.short : RequestLogType.none;
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
}

/// 初始化失败时的最小可用界面：至少让用户看到原因，
/// 而不是停在无反馈的白屏。
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
                SelectableText(
                  "$error",
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// fromSeed 结果缓存：MyApp 每次重建（切换任意设置项触发 Obx）都会
/// 走到这里，相同 seed/brightness 的种子配色没必要反复计算
final Map<String, ColorScheme> _seedSchemeCache = {};

ColorScheme _seedScheme(Color seedColor, Brightness brightness) {
  final key = "$brightness-${seedColor.toARGB32()}";
  return _seedSchemeCache[key] ??=
      ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    bool isDynamicColor = AppSettingsController.instance.isDynamic.value;
    Color styleColor = Color(AppSettingsController.instance.styleColor.value);
    return DynamicColorBuilder(
        builder: ((ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
      ColorScheme? lightColorScheme;
      ColorScheme? darkColorScheme;
      if (lightDynamic != null && darkDynamic != null && isDynamicColor) {
        lightColorScheme = lightDynamic;
        darkColorScheme = darkDynamic;
      } else {
        lightColorScheme = _seedScheme(styleColor, Brightness.light);
        darkColorScheme = _seedScheme(styleColor, Brightness.dark);
      }
      return GetMaterialApp(
        title: "Simple Live",
        theme: AppStyle.lightTheme.copyWith(colorScheme: lightColorScheme),
        darkTheme: AppStyle.darkTheme.copyWith(colorScheme: darkColorScheme),
        themeMode:
            ThemeMode.values[Get.find<AppSettingsController>().themeMode.value],
        initialRoute: RoutePath.kIndex,
        getPages: AppPages.routes,
        //国际化
        locale: const Locale("zh", "CN"),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale("zh", "CN")],
        logWriterCallback: (text, {bool? isError}) {
          Log.addDebugLog(text, (isError ?? false) ? Colors.red : Colors.grey);
          Log.writeLog(text, (isError ?? false) ? Level.error : Level.info);
        },
        // 升级后Android页面过渡动画似乎有BUG
        defaultTransition: Platform.isAndroid ? Transition.cupertino : null,
        //debugShowCheckedModeBanner: false,
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(
          loadingBuilder: ((msg) => const AppLoaddingWidget()),
          //字体大小不跟随系统变化
          builder: (context, child) {
            bool exitDesktopFullscreenWithController() {
              if (Platform.isAndroid || Platform.isIOS) {
                return false;
              }
              if (!Get.isRegistered<LiveRoomController>()) {
                return false;
              }
              final controller = Get.find<LiveRoomController>();
              return controller.exitCurrentFullScreenMode();
            }

            // Fix for HyperOS windowed-mode Flutter bug:
            // - Values > 50 indicate the bug (windowed mode on HyperOS)
            // - Values == 0 are valid for fullscreen/immersive mode and must NOT be treated as abnormal
            const fallbackPadding = EdgeInsets.only(top: 25, bottom: 35);
            const maxNormalPadding = 50.0;

            final mediaQueryData = MediaQuery.of(context);
            final hasAbnormalPadding = mediaQueryData.viewPadding.top > maxNormalPadding;

            final fixedMediaQueryData = hasAbnormalPadding
                ? mediaQueryData.copyWith(
                    viewPadding: fallbackPadding,
                    padding: fallbackPadding,
                    textScaler: const TextScaler.linear(1.0),
                  )
                : mediaQueryData.copyWith(textScaler: const TextScaler.linear(1.0));

            return MediaQuery(
              data: fixedMediaQueryData,
              child: Stack(
              children: [
                //侧键返回
                RawGestureDetector(
                  excludeFromSemantics: true,
                  gestures: <Type, GestureRecognizerFactory>{
                    FourthButtonTapGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                            FourthButtonTapGestureRecognizer>(
                      () => FourthButtonTapGestureRecognizer(),
                      (FourthButtonTapGestureRecognizer instance) {
                        instance.onTapDown = (TapDownDetails details) {
                          //如果处于全屏状态，退出全屏
                          if (exitDesktopFullscreenWithController()) {
                            return;
                          }
                          Get.back();
                        };
                      },
                    ),
                  },
                  child: Focus(
                    autofocus: true,
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.escape) {
                        if (exitDesktopFullscreenWithController()) {
                          return KeyEventResult.handled;
                        }
                      }
                      return KeyEventResult.ignored;
                    },
                    child: child!,
                  ),
                ),

                //查看DEBUG日志按钮
                //只在Debug、Profile模式显示
                Visibility(
                  visible: !kReleaseMode,
                  child: Positioned(
                    right: 12,
                    bottom: 100 + context.mediaQueryViewPadding.bottom,
                    child: Opacity(
                      opacity: 0.4,
                      child: ElevatedButton(
                        child: const Text("DEBUG LOG"),
                        onPressed: () {
                          Get.bottomSheet(
                            const DebugLogPage(),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
            );
          },
        ),
      );
    }));
  }
}
