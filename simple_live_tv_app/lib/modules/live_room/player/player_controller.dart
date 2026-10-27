import 'dart:async';
import 'dart:io';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 缓冲区大小(MB)映射为 demuxer 预读秒数（cache-secs）：
/// 每 4MB 折 1 秒，默认 8MB→3s 维持原有低延迟，30 秒封顶。
/// demuxer-max-bytes 只是容量上限，低码率流会先被秒数卡住，
/// 不联动时调大缓冲区设置实际不生效。HLS 分片粒度大，
/// 3 秒预读容易反复 underrun，下限提高到 6 秒。
int demuxerCacheSecs(int bufferMb, {bool isHls = false}) {
  final secs = (bufferMb / 4).round().clamp(3, 30).toInt();
  return isHls && secs < 6 ? 6 : secs;
}

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
      // mpv 日志门槛：release 只保留 error。
      // TV 端没有日志查看页也没有文件写入，info 级日志对用户无价值，
      // 只会在电视盒子上持续产生字符串分配和平台通道开销。
      logLevel: kDebugMode ? MPVLogLevel.info : MPVLogLevel.error,
    ),
  );

  /// 初始化播放器参数（仅执行一次）
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

    // media_kit 仓库更新导致的问题，临时解决办法
    if (Platform.isAndroid) {
      await pp.setProperty('force-seekable', 'yes');
    }

    // 直播 FLV 断流恢复会重新取流，回退缓存没有实际收益；避免额外驻留。
    await pp.setProperty('demuxer-max-back-bytes', '0');
    await pp.setProperty('demuxer-seekable-cache', 'no');
    // 秒数作为直播缓冲主约束，跟随缓冲区设置推导；open 前会按
    // 当前线路的实际流类型（FLV/HLS）再校正。demuxer-max-bytes 仍提供大小上限。
    await pp.setProperty(
      'cache-secs',
      demuxerCacheSecs(
        AppSettingsController.instance.playerBufferSize.value,
      ).toString(),
    );
    // 网络卡死时快速失败，交给上层切线路，而不是无限等待；
    // demuxer 缓冲已兜住秒级抖动，10 秒读不到数据即可判死
    await pp.setProperty('network-timeout', '10');
    await pp.setProperty(
      'stream-lavf-opts',
      // reconnect_max_retries 设界：死链（如斗鱼 token 过期）不应被
      // mpv 无限静默重连，要快速把错误抛给上层重新取流
      'reconnect_streamed=1,reconnect_at_eof=1,reconnect_delay_max=2,reconnect_max_retries=3',
    );
  }

  /// open 前按目标线路的实际流类型应用 cache-secs，
  /// 属性随下一次 demuxer 建立生效；失败仅记录，不阻断播放
  Future<void> applyDemuxerCacheSecsFor(String url) async {
    try {
      final pp = player.platform as NativePlayer;
      await pp.setProperty(
        'cache-secs',
        demuxerCacheSecs(
          AppSettingsController.instance.playerBufferSize.value,
          isHls: url.toLowerCase().contains('.m3u8'),
        ).toString(),
      );
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 视频控制器
  late final videoController = VideoController(
    player,
    configuration: AppSettingsController.instance.playerCompatMode.value
        ? const VideoControllerConfiguration(
            vo: 'mediacodec_embed',
            hwdec: 'mediacodec',
          )
        : VideoControllerConfiguration(
            enableHardwareAcceleration:
                AppSettingsController.instance.hardwareDecode.value,
            androidAttachSurfaceAfterVideoParameters: false,
          ),
  );
}
mixin PlayerStateMixin on PlayerMixin {
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

  /// 自动隐藏控制器计时器
  Timer? hideControlsTimer;

  /// 自动隐藏提示计时器
  Timer? hideSeekTipTimer;

  Widget? danmakuView;

  var showQualites = false.obs;
  var showLines = false.obs;

  /// 隐藏控制器
  void hideControls() {
    showControlsState.value = false;
    hideControlsTimer?.cancel();
  }

  void setLockState() {
    lockControlsState.value = !lockControlsState.value;
    if (lockControlsState.value) {
      showControlsState.value = false;
    } else {
      showControlsState.value = true;
    }
  }

  /// 显示控制器
  void showControls() {
    showControlsState.value = true;
    resetHideControlsTimer();
  }

  /// 开始隐藏控制器计时
  /// - 当点击控制器上时功能时需要重新计时
  void resetHideControlsTimer() {
    hideControlsTimer?.cancel();

    hideControlsTimer = Timer(
      const Duration(
        seconds: 5,
      ),
      hideControls,
    );
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
}
mixin PlayerDanmakuMixin on PlayerStateMixin {
  /// 弹幕控制器
  DanmakuController? danmakuController;

  void initDanmakuController(DanmakuController e) {
    danmakuController = e;
    // danmakuController?.updateOption(
    //   DanmakuOption(
    //     fontSize: AppSettingsController.instance.danmuSize.value.w,
    //     area: AppSettingsController.instance.danmuArea.value,
    //     duration: AppSettingsController.instance.danmuSpeed.value,
    //     opacity: AppSettingsController.instance.danmuOpacity.value,
    //     strokeWidth: AppSettingsController.instance.danmuStrokeWidth.value.w,
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
mixin PlayerSystemMixin on PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin {
  final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

  /// 初始化一些系统状态
  void initSystem() async {
    // 屏幕常亮
    WakelockPlus.enable();

    // 开始隐藏计时
    resetHideControlsTimer();
  }

  /// 释放一些系统状态
  Future resetSystem() async {
    await WakelockPlus.disable();
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
}

class PlayerController extends BaseController
    with PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin, PlayerSystemMixin {
  @override
  void onInit() {
    initSystem();
    initStream();
    super.onInit();
  }

  var width = 0.obs;
  var height = 0.obs;

  StreamSubscription<String>? _errorSubscription;
  StreamSubscription? _completedSubscription;
  StreamSubscription? _videoParamsSubscription;
  StreamSubscription? _logSubscription;
  StreamSubscription<bool>? _playingSubscription;

  /// mpv 日志订阅与事件打印的门禁：profile 用于性能测量，
  /// 订阅 mpv log 本身就有解析开销，必须与普通日志一起默认静默
  bool get _shouldLogPlayerEvents => kDebugMode;

  void initStream() {
    _errorSubscription = player.stream.error.listen((event) {
      if (_shouldLogPlayerEvents) {
        Log.d("播放器错误：$event");
      }
      if (event.contains('no sound.')) {
        return;
      }
      //SmartDialog.showToast(event);
      mediaError(event);
    });

    _completedSubscription = player.stream.completed.listen((event) {
      if (event) {
        mediaEnd();
      }
    });

    _playingSubscription = player.stream.playing.listen((event) {
      if (event) {
        onPlayingStarted();
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
        Log.w('videoParams: W:${player.state.width}  H:${player.state.height}');
      }
      width.value = player.state.width ?? 0;
      height.value = player.state.height ?? 0;
    });
  }

  void disposeStream() {
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _videoParamsSubscription?.cancel();
    _logSubscription?.cancel();
    _playingSubscription?.cancel();
  }

  /// 播放器进入播放态的钩子：由子类覆盖，
  /// 用于首帧链路计时与恢复结果记账
  void onPlayingStarted() {}

  void mediaEnd() {}

  void mediaError(String error) {}

  @override
  void onClose() async {
    Log.w("播放器关闭");
    disposeStream();
    // 先停流再做平台侧清理：resetSystem 的平台调用耗时较长，
    // 不先停流会在页面销毁后继续出声
    await player.stop();
    disposeDanmakuController();
    hideControlsTimer?.cancel();
    hideSeekTipTimer?.cancel();
    await resetSystem();
    await player.dispose();
    super.onClose();
  }
}
