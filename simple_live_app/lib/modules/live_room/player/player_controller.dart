import 'dart:async';
import 'dart:io';
import 'package:auto_orientation_v2/auto_orientation_v2.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:floating/floating.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/custom_throttle.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:simple_live_app/services/system_control_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

mixin PlayerMixin {
  GlobalKey<VideoState> globalPlayerKey = GlobalKey<VideoState>();
  GlobalKey globalDanmuKey = GlobalKey();

  /// 播放器参数初始化任务：表达"完成"而非"已发起"，
  /// 并发调用共享同一任务；失败时清空，允许后续重试
  Future<void>? _playerInitTask;

  /// 播放器实例
  late final player = Player(
    configuration: PlayerConfiguration(
      title: "Simple Live Player",
      // 设置 demuxer-max-bytes（媒体缓冲上限）。
      // media_kit 通过 PlayerConfiguration.bufferSize 在内核启动时一次性注入，
      // 比 setProperty 更可靠（参见 media_kit #549）。
      bufferSize:
          AppSettingsController.instance.playerBufferSize.value * 1024 * 1024,
      logLevel: AppSettingsController.instance.logEnable.value
          ? MPVLogLevel.info
          : MPVLogLevel.error,
    ),
  );

  /// 初始化播放器参数（仅执行一次）
  /// - ao / force-seekable / 直播流缓存与重连参数
  Future<void> initializePlayer() {
    final pending = _playerInitTask;
    if (pending != null) return pending;
    final task = _doInitializePlayer();
    _playerInitTask = task;
    task.catchError((_) {
      if (identical(_playerInitTask, task)) {
        _playerInitTask = null;
      }
    });
    return task;
  }

  Future<void> _doInitializePlayer() async {
    var pp = player.platform as NativePlayer;
    // 设置音频输出驱动
    if (AppSettingsController.instance.customPlayerOutput.value) {
      await pp.setProperty(
        'ao',
        AppSettingsController.instance.audioOutputDriver.value,
      );
    }
    // media_kit 仓库更新导致的问题，临时解决办法
    if (Platform.isAndroid) {
      await pp.setProperty('force-seekable', 'yes');
    }

    // 直播 FLV 断流恢复会重新取流，回退缓存没有实际收益；避免额外驻留。
    await pp.setProperty('demuxer-max-back-bytes', '0');
    await pp.setProperty('demuxer-seekable-cache', 'no');
    // 秒数作为直播缓冲主约束，demuxer-max-bytes 仍提供大小上限。
    await pp.setProperty('cache-secs', '3');
    // 网络卡死时快速失败，交给上层切线路，而不是无限等待
    await pp.setProperty('network-timeout', '15');
    // HTTP/HLS 分片请求断流自动重连，减少上层 mediaError 重试
    await pp.setProperty(
      'stream-lavf-opts',
      // reconnect_max_retries 设界：死链（如斗鱼 token 过期）不应被
      // mpv 无限静默重连，要快速把错误抛给上层重新取流
      'reconnect_streamed=1,reconnect_at_eof=1,reconnect_delay_max=2,reconnect_max_retries=3',
    );
  }

  /// 视频控制器
  late final videoController = VideoController(
    player,
    configuration: AppSettingsController.instance.customPlayerOutput.value
        ? VideoControllerConfiguration(
            vo: AppSettingsController.instance.videoOutputDriver.value,
            hwdec: AppSettingsController.instance.videoHardwareDecoder.value,
          )
        : AppSettingsController.instance.playerCompatMode.value
            ? const VideoControllerConfiguration(
                vo: 'mediacodec_embed',
                hwdec: 'mediacodec',
              )
            : VideoControllerConfiguration(
                hwdec: AppSettingsController.instance.hardwareDecode.value
                    ? (Platform.isMacOS ? 'videotoolbox-copy' : 'auto')
                    : 'no',
                enableHardwareAcceleration:
                    AppSettingsController.instance.hardwareDecode.value,
                androidAttachSurfaceAfterVideoParameters: false,
              ),
  );
}

/// 控制器可见性评估周期
const Duration _kControlsEvaluateInterval = Duration(milliseconds: 250);

/// 空闲满多少拍后自动隐藏控制器（8 × 250ms = 2s）
const int _kControlsHideDelayTicks = 8;

mixin PlayerStateMixin on PlayerMixin {
  ///音量控制条计时器
  Timer? hidevolumeTimer;

  /// 是否进入桌面端小窗
  RxBool smallWindowState = false.obs;

  /// 是否显示弹幕
  RxBool showDanmakuState = false.obs;

  /// 是否显示控制器
  RxBool showControlsState = false.obs;

  /// 是否显示设置窗口
  RxBool showSettingState = false.obs;

  /// 是否显示弹幕设置窗口
  RxBool showDanmakuSettingState = false.obs;

  /// 是否处于锁定控制器状态
  RxBool lockControlsState = false.obs;

  /// 是否处于全屏状态
  RxBool fullScreenState = false.obs;

  /// 显示手势Tip
  RxBool showGestureTip = false.obs;

  /// 手势Tip文本
  RxString gestureTipText = "".obs;

  /// 显示提示底部Tip
  RxBool showBottomTip = false.obs;

  /// 提示底部Tip文本
  RxString bottomTipText = "".obs;

  /// 控制器可见性评估定时器：周期性根据「空闲拍数」推导显隐，
  /// 交互事件只负责重置计数——不存在计时器被取消后无人重武装的死态
  /// - 点击视频/控制条、指针在播放区或控制条上移动，都会重置空闲计数
  /// - 空闲满 [_kControlsHideDelayTicks] 拍自动隐藏，指针停在控制条上也不例外
  /// - 锁定时暂停自动隐藏，锁定按钮的显隐完全由点击控制
  int _controlsIdleTicks = _kControlsHideDelayTicks; // 初始视为已空闲
  Timer? _controlsEvaluateTimer;

  /// 控制条（毛玻璃气泡/底栏）上的指针移入/移动/移出：均视为交互
  void onControlsBarEnter(PointerEnterEvent event) => markControlsActivity();

  void onControlsBarHover(PointerHoverEvent event) => markControlsActivity();

  void onControlsBarExit(PointerExitEvent event) => markControlsActivity();

  /// 自动隐藏提示计时器
  Timer? hideSeekTipTimer;

  /// 键盘音量/静音提示的自动隐藏计时器
  Timer? _keyboardVolumeTipTimer;

  /// 静音前的音量快照（用于恢复）
  double? _mutedVolume;

  /// 是否为竖屏直播间
  var isVertical = false.obs;

  Widget? danmakuView;

  var showQualites = false.obs;
  var showLines = false.obs;

  /// 隐藏控制器（点击切换/锁定/小窗等主动隐藏）
  void hideControls() {
    _controlsIdleTicks = _kControlsHideDelayTicks;
    showControlsState.value = false;
  }

  void setLockState() {
    lockControlsState.value = !lockControlsState.value;
    if (lockControlsState.value) {
      hideControls();
    } else {
      showControls();
    }
  }

  /// 显示控制器（主动操作：单击视频、解锁），不受锁定状态限制
  void showControls() {
    _controlsIdleTicks = 0;
    showControlsState.value = true;
  }

  /// 记录一次控制器交互：重置空闲计数，未锁定时立即显示
  /// - 桌面端指针移动（播放区/控制条）、控制条上的按下都走这里
  void markControlsActivity() {
    _controlsIdleTicks = 0;
    if (!lockControlsState.value && !showControlsState.value) {
      showControlsState.value = true;
    }
  }

  /// 启动可见性评估器（进房时调用一次）
  void startControlsEvaluator() {
    _controlsEvaluateTimer?.cancel();
    _controlsEvaluateTimer = Timer.periodic(
      _kControlsEvaluateInterval,
      (_) => _evaluateControlsVisibility(),
    );
  }

  /// 周期推导控制器可见性：空闲满 2 秒自动隐藏；锁定时只累计不应用
  void _evaluateControlsVisibility() {
    if (_controlsIdleTicks < _kControlsHideDelayTicks) {
      _controlsIdleTicks++;
    }
    if (lockControlsState.value) return;
    final visible = _controlsIdleTicks < _kControlsHideDelayTicks;
    if (visible != showControlsState.value) {
      showControlsState.value = visible;
    }
  }

  void updateScaleMode() {
    var boxFit = BoxFit.contain;
    double? aspectRatio;
    if (player.state.width != null && player.state.height != null) {
      aspectRatio = player.state.width! / player.state.height!;
    }

    if (AppSettingsController.instance.scaleMode.value == 0) {
      boxFit = BoxFit.contain;
    } else if (AppSettingsController.instance.scaleMode.value == 1) {
      boxFit = BoxFit.fill;
    } else if (AppSettingsController.instance.scaleMode.value == 2) {
      boxFit = BoxFit.cover;
    } else if (AppSettingsController.instance.scaleMode.value == 3) {
      boxFit = BoxFit.contain;
      aspectRatio = 16 / 9;
    } else if (AppSettingsController.instance.scaleMode.value == 4) {
      boxFit = BoxFit.contain;
      aspectRatio = 4 / 3;
    }
    globalPlayerKey.currentState?.update(
      aspectRatio: aspectRatio,
      fit: boxFit,
    );
  }

  /// 全屏播放器专用 FocusNode（用于接收键盘快捷键）
  FocusNode? _playerFocusNode;
  FocusNode get playerFocusNode {
    _playerFocusNode ??= FocusNode(debugLabel: 'playerFullscreen');
    return _playerFocusNode!;
  }

  /// 键盘调节音量（步进 5），同时给出短暂提示
  void adjustVolume(int delta) {
    double next = AppSettingsController.instance.playerVolume.value + delta;
    if (next < 0) next = 0;
    if (next > 100) next = 100;
    player.setVolume(next);
    AppSettingsController.instance.setPlayerVolume(next);
    gestureTipText.value = "音量 ${next.toInt()}%";
    showGestureTip.value = true;
    _keyboardVolumeTipTimer?.cancel();
    _keyboardVolumeTipTimer = Timer(const Duration(milliseconds: 800), () {
      showGestureTip.value = false;
    });
  }

  /// 切换静音（再次调用恢复上次音量）
  void toggleMute() {
    final current = AppSettingsController.instance.playerVolume.value;
    double target;
    if (current > 0) {
      _mutedVolume = current;
      target = 0;
      gestureTipText.value = "静音";
    } else {
      target = _mutedVolume ?? 100;
      gestureTipText.value = "音量 ${target.toInt()}%";
    }
    player.setVolume(target);
    AppSettingsController.instance.setPlayerVolume(target);
    showGestureTip.value = true;
    _keyboardVolumeTipTimer?.cancel();
    _keyboardVolumeTipTimer = Timer(const Duration(milliseconds: 800), () {
      showGestureTip.value = false;
    });
  }
}
mixin PlayerDanmakuMixin on PlayerStateMixin {
  /// 弹幕控制器
  DanmakuController? danmakuController;

  void initDanmakuController(DanmakuController e) {
    danmakuController = e;
    // danmakuController?.updateOption(
    //   DanmakuOption(
    //     fontSize: AppSettingsController.instance.danmuSize.value,
    //     area: AppSettingsController.instance.danmuArea.value,
    //     duration: AppSettingsController.instance.danmuSpeed.value,
    //     opacity: AppSettingsController.instance.danmuOpacity.value,
    //     strokeWidth: AppSettingsController.instance.danmuStrokeWidth.value,
    //     fontWeight: FontWeight
    //         .values[AppSettingsController.instance.danmuFontWeight.value],
    //   ),
    // );
  }

  void updateDanmuOption(DanmakuOption? option) {
    if (danmakuController == null || option == null) return;
    danmakuController!.updateOption(option);
  }

  void disposeDanmakuController() {
    danmakuController?.clear();
  }

  void addDanmaku(List<DanmakuContentItem> items) {
    if (!showDanmakuState.value) {
      return;
    }
    for (var item in items) {
      danmakuController?.addDanmaku(item);
    }
  }
}
class _PlayerWindowListener extends WindowListener {
  final PlayerSystemMixin mixin;
  _PlayerWindowListener(this.mixin);

  @override
  void onWindowEnterFullScreen() {
    mixin.fullScreenState.value = true;
  }

  @override
  void onWindowLeaveFullScreen() {
    mixin.fullScreenState.value = false;
  }
}

mixin PlayerSystemMixin on PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin {
  final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

  final pip = Floating();
  StreamSubscription<PiPStatus>? _pipSubscription;
  _PlayerWindowListener? _windowListener;

  bool _desktopFullScreenTransitioning = false;
  bool? _pendingDesktopFullScreenState;
  DateTime? _desktopLastToggleAt;
  bool? _desktopLastToggleTarget;
  DateTime? _desktopLastExitModeRequestAt;

  //final VolumeController volumeController = VolumeController();

  bool get _isDesktopPlatform => !(Platform.isAndroid || Platform.isIOS);

  void _startDesktopFullScreenSync() {
    if (!_isDesktopPlatform) return;
    if (_windowListener == null) {
      _windowListener = _PlayerWindowListener(this);
      windowManager.addListener(_windowListener!);
    }
  }

  Future<void> _setDesktopFullScreen(bool fullScreen) async {
    if (!_isDesktopPlatform) {
      return;
    }

    final now = DateTime.now();
    final recentToggle =
        _desktopLastToggleAt != null &&
            now.difference(_desktopLastToggleAt!) <
                const Duration(milliseconds: 600);
    if (recentToggle && _desktopLastToggleTarget == fullScreen) {
      return;
    }

    if (_desktopFullScreenTransitioning) {
      _pendingDesktopFullScreenState = fullScreen;
      return;
    }

    _desktopFullScreenTransitioning = true;
    _desktopLastToggleAt = now;
    _desktopLastToggleTarget = fullScreen;
    fullScreenState.value = fullScreen;
    try {
      final current = await windowManager.isFullScreen();
      if (current != fullScreen) {
        await windowManager.setFullScreen(fullScreen);
      }
    } catch (e) {
      Log.logPrint(e);
    } finally {
      _desktopFullScreenTransitioning = false;
      final pending = _pendingDesktopFullScreenState;
      _pendingDesktopFullScreenState = null;
      if (pending != null && pending != fullScreen) {
        _setDesktopFullScreen(pending);
      } else {
        _syncDesktopFullScreenState();
      }
    }
  }

  void _syncDesktopFullScreenState() async {
    if (!_isDesktopPlatform) return;
    try {
      fullScreenState.value = await windowManager.isFullScreen();
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 初始化一些系统状态
  void initSystem() async {
    SystemControlService.instance.setShowSystemVolumeUI(false);

    // 屏幕常亮
    //WakelockPlus.enable();

    // 启动控制器可见性评估
    startControlsEvaluator();
    _startDesktopFullScreenSync();

    // 进入全屏模式
    if (AppSettingsController.instance.autoFullScreen.value) {
      enterFullScreen();
    }
  }

  /// 释放一些系统状态
  Future resetSystem() async {
    _pipSubscription?.cancel();

    if (_windowListener != null) {
      windowManager.removeListener(_windowListener!);
      _windowListener = null;
    }

    _desktopFullScreenTransitioning = false;
    _pendingDesktopFullScreenState = null;
    _desktopLastToggleAt = null;
    _desktopLastToggleTarget = null;
    _desktopLastExitModeRequestAt = null;
    //pip.dispose();
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );

    await setPortraitOrientation();
    await SystemControlService.instance.resetBrightness();

    await WakelockPlus.disable();
  }

  /// 进入全屏
  void enterFullScreen() {
    if (Platform.isAndroid || Platform.isIOS) {
      fullScreenState.value = true;
      //全屏
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      if (!isVertical.value) {
        //横屏
        setLandscapeOrientation();
      }
    } else {
      _setDesktopFullScreen(true);
    }
    //danmakuController?.clear();
    // 桌面端进入全屏后把键盘焦点交给播放器（接收快捷键）
    if (!(Platform.isAndroid || Platform.isIOS)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        playerFocusNode.requestFocus();
      });
    }
  }

  /// 退出全屏
  void exitFull() {
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge,
          overlays: SystemUiOverlay.values);
      setPortraitOrientation();
      fullScreenState.value = false;
    } else {
      _setDesktopFullScreen(false);
    }

    //danmakuController?.clear();
  }

  /// 退出当前显示模式（优先退出小窗，其次退出全屏）
  bool exitCurrentFullScreenMode() {
    if (_isDesktopPlatform) {
      final now = DateTime.now();
      final last = _desktopLastExitModeRequestAt;
      _desktopLastExitModeRequestAt = now;
      if (last != null &&
          now.difference(last) < const Duration(milliseconds: 300)) {
        // 高频重复触发（如快速连按 ESC）时，保持当前过渡流程，避免重复切换窗口状态。
        return smallWindowState.value ||
            fullScreenState.value ||
            _desktopFullScreenTransitioning;
      }
    }

    if (smallWindowState.value) {
      exitSmallWindow();
      return true;
    }
    if (fullScreenState.value) {
      exitFull();
      return true;
    }
    if (_isDesktopPlatform && _desktopFullScreenTransitioning) {
      return true;
    }
    return false;
  }

  Size? _lastWindowSize;
  Offset? _lastWindowPosition;

  ///小窗模式()
  void enterSmallWindow() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      fullScreenState.value = true;
      smallWindowState.value = true;

      await SystemControlService.instance.enterDesktopSmallWindow(
        videoWidth: player.state.width?.toDouble() ?? 16,
        videoHeight: player.state.height?.toDouble() ?? 9,
      );
    }
  }

  ///退出小窗模式()
  void exitSmallWindow() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      fullScreenState.value = false;
      smallWindowState.value = false;
      await SystemControlService.instance.exitDesktopSmallWindow();
    }
  }

  /// 设置横屏
  Future setLandscapeOrientation() async {
    if (await beforeIOS16()) {
      AutoOrientation.landscapeAutoMode();
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// 设置竖屏
  Future setPortraitOrientation() async {
    if (await beforeIOS16()) {
      AutoOrientation.portraitAutoMode();
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  /// 是否是IOS16以下
  Future<bool> beforeIOS16() async {
    if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      var version = info.systemVersion;
      var versionInt = int.tryParse(version.split('.').first) ?? 0;
      return versionInt < 16;
    } else {
      return false;
    }
  }

  Future saveScreenshot() async {
    try {
      SmartDialog.showLoading(msg: "正在保存截图");
      //检查相册权限,仅iOS需要
      var permission = await Utils.checkPhotoPermission();
      if (!permission) {
        SmartDialog.showToast("没有相册权限");
        SmartDialog.dismiss(status: SmartStatus.loading);
        return;
      }

      var imageData = await player.screenshot();
      if (imageData == null) {
        SmartDialog.showToast("截图失败,数据为空");
        SmartDialog.dismiss(status: SmartStatus.loading);
        return;
      }

      if (Platform.isIOS || Platform.isAndroid) {
        await ImageGallerySaverPlus.saveImage(
          imageData,
        );
        SmartDialog.showToast("已保存截图至相册");
      } else {
        //选择保存文件夹
        var path = await FilePicker.platform.saveFile(
          allowedExtensions: ["jpg"],
          type: FileType.image,
          fileName: "${DateTime.now().millisecondsSinceEpoch}.jpg",
        );
        if (path == null) {
          SmartDialog.showToast("取消保存");
          SmartDialog.dismiss(status: SmartStatus.loading);
          return;
        }
        var file = File(path);
        await file.writeAsBytes(imageData);
        SmartDialog.showToast("已保存截图至${file.path}");
      }
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("截图失败");
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 开启小窗播放前弹幕状态
  bool danmakuStateBeforePIP = false;

  Future enablePIP() async {
    if (!Platform.isAndroid) {
      return;
    }
    if (await pip.isPipAvailable == false) {
      SmartDialog.showToast("设备不支持小窗播放");
      return;
    }
    danmakuStateBeforePIP = showDanmakuState.value;
    //关闭并清除弹幕
    if (AppSettingsController.instance.pipHideDanmu.value &&
        danmakuStateBeforePIP) {
      showDanmakuState.value = false;
    }
    danmakuController?.clear();
    //关闭控制器
    hideControls();

    //监听事件
    var width = player.state.width ?? 0;
    var height = player.state.height ?? 0;
    Rational ratio = const Rational.landscape();
    if (height > width) {
      ratio = const Rational.vertical();
    } else {
      ratio = const Rational.landscape();
    }
    await pip.enable(
      ImmediatePiP(
        aspectRatio: ratio,
      ),
    );

    _pipSubscription ??= pip.pipStatusStream.listen((event) {
      if (event == PiPStatus.disabled) {
        danmakuController?.clear();
        showDanmakuState.value = danmakuStateBeforePIP;
      }
      Log.w(event.toString());
    });
  }
}
mixin PlayerGestureControlMixin
    on PlayerStateMixin, PlayerMixin, PlayerSystemMixin {
  /// 单击显示/隐藏控制器
  void onTap() {
    // 桌面端全屏时确保键盘焦点回到播放器（点击按钮/弹窗后焦点可能丢失）
    if (_isDesktopPlatform && fullScreenState.value) {
      playerFocusNode.requestFocus();
    }
    if (showControlsState.value) {
      hideControls();
    } else {
      showControls();
    }
  }

  //桌面端操控
  void onEnter(PointerEnterEvent event) {
    markControlsActivity();
  }

  void onExit(PointerExitEvent event) {
    // 指针离开播放区（窗口/播放器范围）立即隐藏
    if (showControlsState.value) {
      hideControls();
    }
  }

  void onHover(PointerHoverEvent event) {
    // 桌面端约定：鼠标一动就显示控制条，静止后由评估器自动隐藏
    markControlsActivity();
  }

  /// 双击全屏/退出全屏
  void onDoubleTap(TapDownDetails details) {
    if (lockControlsState.value) {
      return;
    }
    if (fullScreenState.value) {
      exitFull();
    } else {
      enterFullScreen();
    }
  }

  bool verticalDragging = false;
  bool leftVerticalDrag = false;
  var _currentVolume = 0.0;
  var _currentBrightness = 1.0;
  var verStartPosition = 0.0;

  DelayedThrottle? throttle;

  /// 竖向手势开始
  void onVerticalDragStart(DragStartDetails details) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }

    final dy = details.globalPosition.dy;
    // 开始位置必须是中间2/4的位置
    if (dy < Get.height * 0.25 || dy > Get.height * 0.75) {
      return;
    }

    verStartPosition = dy;
    leftVerticalDrag = details.globalPosition.dx < Get.width / 2;

    throttle = DelayedThrottle(200);

    verticalDragging = true;
    // 桌面端音量由播放器自身管理（与 showVolumeSlider 一致），
    // SystemControlService 在桌面端是空操作，会导致手势 UI 变化但音量不变。
    if (Platform.isAndroid || Platform.isIOS) {
      _currentVolume = await SystemControlService.instance.getVolume();
    } else {
      _currentVolume = AppSettingsController.instance.playerVolume.value / 100;
    }
    _currentBrightness = await SystemControlService.instance.getBrightness();

    // 只有在支持亮度的平台上才显示左侧亮度的调整 UI
    // 右侧音量则直接显示 UI
    if (!leftVerticalDrag || SystemControlService.instance.supportBrightnessControl) {
      showGestureTip.value = true;
    }
  }

  /// 竖向手势更新
  void onVerticalDragUpdate(DragUpdateDetails e) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }
    if (verticalDragging == false) return;

    Log.logPrint("$verStartPosition/${e.globalPosition.dy}");

    if (leftVerticalDrag) {
      if (SystemControlService.instance.supportBrightnessControl) {
        setGestureBrightness(e.globalPosition.dy);
      }
    } else {
      setGestureVolume(e.globalPosition.dy);
    }
  }

  int lastVolume = -1; // it's ok to be -1

  void setGestureVolume(double dy) {
    double value = 0.0;
    double seek;
    if (dy > verStartPosition) {
      value = ((dy - verStartPosition) / (Get.height * 0.5));

      seek = _currentVolume - value;
      if (seek < 0) {
        seek = 0;
      }
    } else {
      value = ((dy - verStartPosition) / (Get.height * 0.5));
      seek = value.abs() + _currentVolume;
      if (seek > 1) {
        seek = 1;
      }
    }
    int volume = _convertVolume((seek * 100).round());
    if (volume == lastVolume) {
      return;
    }
    lastVolume = volume;
    // update UI outside throttle to make it more fluent
    gestureTipText.value = "音量 $volume%";
    throttle?.invoke(() async => await _realSetVolume(volume));
  }

  // 0 to 100, 5 step each
  int _convertVolume(int volume) {
    return (volume / 5).round() * 5;
  }

  Future _realSetVolume(int volume) async {
    Log.logPrint(volume);
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemControlService.instance.setVolume(volume / 100);
    } else {
      // 桌面端走播放器音量（0-100），与 showVolumeSlider 一致
      await player.setVolume(volume.toDouble());
      AppSettingsController.instance.setPlayerVolume(volume.toDouble());
    }
  }

  void setGestureBrightness(double dy) {
    double value = 0.0;
    if (dy > verStartPosition) {
      value = ((dy - verStartPosition) / (Get.height * 0.5));

      var seek = _currentBrightness - value;
      if (seek < 0) {
        seek = 0;
      }
      SystemControlService.instance.setBrightness(seek);

      gestureTipText.value = "亮度 ${(seek * 100).toInt()}%";
      Log.logPrint(value);
    } else {
      value = ((dy - verStartPosition) / (Get.height * 0.5));
      var seek = value.abs() + _currentBrightness;
      if (seek > 1) {
        seek = 1;
      }

      SystemControlService.instance.setBrightness(seek);
      gestureTipText.value = "亮度 ${(seek * 100).toInt()}%";
      Log.logPrint(value);
    }
  }

  /// 竖向手势完成
  void onVerticalDragEnd(DragEndDetails details) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }
    throttle = null;
    verticalDragging = false;
    leftVerticalDrag = false;
    showGestureTip.value = false;
  }
}

class PlayerController extends BaseController
    with
        PlayerMixin,
        PlayerStateMixin,
        PlayerDanmakuMixin,
        PlayerSystemMixin,
        PlayerGestureControlMixin {
  @override
  void onInit() {
    initSystem();
    initStream();
    //设置音量
    player.setVolume(AppSettingsController.instance.playerVolume.value);
    super.onInit();
  }

  StreamSubscription<String>? _errorSubscription;
  StreamSubscription? _completedSubscription;
  StreamSubscription? _videoParamsSubscription;
  StreamSubscription? _logSubscription;
  StreamSubscription? _playingSubscription;

  bool get _shouldLogPlayerEvents =>
      !kReleaseMode || AppSettingsController.instance.logEnable.value;

  void _updateVerticalByPlayerSize() {
    final vertical = (player.state.height ?? 9) > (player.state.width ?? 16);
    if (isVertical.value != vertical) {
      isVertical.value = vertical;
    }
  }

  void initStream() {
    _errorSubscription = player.stream.error.listen((event) {
      if (_shouldLogPlayerEvents) {
        Log.d("播放器错误：$event");
      }
      // 跳过无音频输出的错误
      // Could not open/initialize audio device -> no sound.
      if (event.contains('no sound.')) {
        return;
      }
      //SmartDialog.showToast(event);
      mediaError(event);
    });

    _playingSubscription = player.stream.playing.listen((event) {
      if (event) {
        WakelockPlus.enable();
        if (_shouldLogPlayerEvents) {
          Log.d("Playing");
        }
        onPlayingStarted();
      }
    });

    _completedSubscription = player.stream.completed.listen((event) {
      if (event) {
        mediaEnd();
      }
    });
    if (_shouldLogPlayerEvents) {
      _logSubscription = player.stream.log.listen((event) {
        Log.d("播放器日志：$event");
      });
    }
    // 合并为单一 videoParams 订阅：width/height 同源，避免重复回调与日志
    _videoParamsSubscription = player.stream.videoParams.listen((_) {
      if (_shouldLogPlayerEvents) {
        Log.d('videoParams: W:${player.state.width}  H:${player.state.height}');
      }
      _updateVerticalByPlayerSize();
    });
  }

  void disposeStream() {
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _videoParamsSubscription?.cancel();
    _logSubscription?.cancel();
    _pipSubscription?.cancel();
    _playingSubscription?.cancel();
  }

  /// 播放器进入播放态的钩子：由子类覆盖，
  /// 用于首帧链路计时与恢复结果记账
  void onPlayingStarted() {}

  void mediaEnd() {
    WakelockPlus.disable();
  }

  void mediaError(String error) {
    WakelockPlus.disable();
  }

  Future<void> showDebugInfo() async {
    final nativePlayer = player.platform as NativePlayer;
    final mpvProperties = await Future.wait([
      _readMpvProperty(nativePlayer, 'video-codec'),
      _readMpvProperty(nativePlayer, 'hwdec-current'),
      _readMpvProperty(nativePlayer, 'demuxer-cache-state/fw-bytes'),
      _readMpvProperty(nativePlayer, 'demuxer-cache-state/total-bytes'),
      _readMpvProperty(nativePlayer, 'demuxer-cache-state/cache-duration'),
    ]);
    final codec = mpvProperties[0];
    final hwdec = mpvProperties[1];
    final cacheState = _formatDemuxerCache(
      forwardBytes: mpvProperties[2],
      totalBytes: mpvProperties[3],
      duration: mpvProperties[4],
    );

    await Utils.showBottomSheet(
      title: "播放信息",
      child: ListView(
        children: [
          ListTile(
            title: const Text("Resolution"),
            subtitle: Text('${player.state.width}x${player.state.height}'),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text:
                      "Resolution\n${player.state.width}x${player.state.height}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("VideoParams"),
            subtitle: Text(player.state.videoParams.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "VideoParams\n${player.state.videoParams}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("Video codec"),
            subtitle: Text(codec),
            onTap: () => Clipboard.setData(ClipboardData(text: codec)),
          ),
          ListTile(
            title: const Text("HW decoder (active)"),
            subtitle: Text(hwdec),
            onTap: () => Clipboard.setData(ClipboardData(text: hwdec)),
          ),
          ListTile(
            title: const Text("Demuxer cache"),
            subtitle: Text(cacheState),
            onTap: () => Clipboard.setData(ClipboardData(text: cacheState)),
          ),
          ListTile(
            title: const Text("弹幕解码指标"),
            subtitle: Text(LiveMetrics.instance.danmakuSummary()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: LiveMetrics.instance.danmakuSummary(),
                ),
              );
            },
          ),
          ListTile(
            title: const Text("断流恢复指标"),
            subtitle: Text(LiveMetrics.instance.recoverySummary()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: LiveMetrics.instance.recoverySummary(),
                ),
              );
            },
          ),
          ListTile(
            title: const Text("AudioParams"),
            subtitle: Text(player.state.audioParams.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "AudioParams\n${player.state.audioParams}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("Media"),
            subtitle: Text(player.state.playlist.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "Media\n${player.state.playlist}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("AudioTrack"),
            subtitle: Text(player.state.track.audio.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "AudioTrack\n${player.state.track.audio}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("VideoTrack"),
            subtitle: Text(player.state.track.video.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "VideoTrack\n${player.state.track.video}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("AudioBitrate"),
            subtitle: Text(player.state.audioBitrate.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "AudioBitrate\n${player.state.audioBitrate}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("Volume"),
            subtitle: Text(player.state.volume.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "Volume\n${player.state.volume}",
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<String> _readMpvProperty(
    NativePlayer nativePlayer,
    String property,
  ) async {
    try {
      final value = await nativePlayer
          .getProperty(property, waitForInitialization: false)
          .timeout(const Duration(seconds: 1));
      return value.trim().isEmpty ? '不可用' : value;
    } catch (_) {
      return '不可用';
    }
  }

  String _formatDemuxerCache({
    required String forwardBytes,
    required String totalBytes,
    required String duration,
  }) {
    final seconds = double.tryParse(duration);
    final durationText = seconds == null
        ? ''
        : ', ${seconds.toStringAsFixed(1)}s cached';
    return '${_formatCacheBytes(forwardBytes)} forward / '
        '${_formatCacheBytes(totalBytes)} total$durationText';
  }

  String _formatCacheBytes(String value) {
    final bytes = double.tryParse(value);
    if (bytes == null) return 'N/A';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  @override
  void onClose() async {
    Log.w("播放器关闭");
    if (smallWindowState.value) {
      exitSmallWindow();
    }
    disposeStream();
    // 先停流再做平台侧清理：resetSystem 的方向/亮度调用耗时较长，
    // 不先停流会在页面销毁后继续出声
    await player.stop();
    disposeDanmakuController();
    _keyboardVolumeTipTimer?.cancel();
    hidevolumeTimer?.cancel();
    _controlsEvaluateTimer?.cancel();
    hideSeekTipTimer?.cancel();
    _playerFocusNode?.dispose();
    _playerFocusNode = null;
    await resetSystem();
    await player.dispose();
    super.onClose();
  }
}
