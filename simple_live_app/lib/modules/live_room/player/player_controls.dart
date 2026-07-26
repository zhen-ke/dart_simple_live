import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:window_manager/window_manager.dart';
import 'package:simple_live_app/widgets/superchat_card.dart';
import 'dart:async';
import 'package:simple_live_core/simple_live_core.dart';

Widget playerControls(
  VideoState videoState,
  LiveRoomController controller,
) {
  return Obx(() {
    if (controller.fullScreenState.value) {
      return buildFullControls(
        videoState,
        controller,
      );
    }
    return buildControls(
      videoState.context.orientation == Orientation.portrait,
      videoState,
      controller,
    );
  });
}

Widget buildFullControls(
  VideoState videoState,
  LiveRoomController controller,
) {
  var padding = MediaQuery.of(videoState.context).padding;
  GlobalKey volumeButtonkey = GlobalKey();
  return Focus(
    focusNode: controller.playerFocusNode,
    autofocus: true,
    onKeyEvent: (node, event) => _onPlayerKeyEvent(event, controller),
    child: DragToMoveArea(
      child: Stack(
        children: [
          Container(),
          buildDanmuView(videoState, controller),

        // 左下角SC显示
        Obx(
          () => Visibility(
            visible: AppSettingsController.instance.playershowSuperChat.value &&
                ((!Platform.isAndroid && !Platform.isIOS) ||
                    controller.fullScreenState.value),
            child: Positioned(
              left: 24,
              bottom: 24,
              child: PlayerSuperChatOverlay(controller: controller),
            ),
          ),
        ),

        Center(
          child: // 中间
              PlayerBufferingIndicator(
            controller: videoState.widget.controller,
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            onTap: controller.onTap,
            // 桌面端不注册双击（避免 GestureDetector 等待 ~300ms 判定，单击切换控制条更跟手）
            // 全屏切换已由 F / Esc / 底栏按钮覆盖
            onDoubleTapDown: (Platform.isAndroid || Platform.isIOS)
                ? controller.onDoubleTap
                : null,
            onLongPress: () {
              if (controller.lockControlsState.value) {
                return;
              }
              showFollowUser(controller);
            },
            onVerticalDragStart: controller.onVerticalDragStart,
            onVerticalDragUpdate: controller.onVerticalDragUpdate,
            onVerticalDragEnd: controller.onVerticalDragEnd,
            child: MouseRegion(
              onHover: (PointerHoverEvent event) {
                controller.onHover(event, videoState.context);
              },
              child: Container(
                width: double.infinity,
                height: double.infinity,
                color: Colors.transparent,
                // child: Visibility(
                //   //拖拽区域
                //   visible: controller.smallWindowState.value,
                //   child: DragToMoveArea(
                //       child: Container(
                //     width: double.infinity,
                //     height: double.infinity,
                //     color: Colors.transparent,
                //   )),
                // ),
              ),
            ),
          ),
        ),

        // 顶部
        Obx(
          () => AnimatedPositioned(
            left: padding.left + 16,
            right: padding.right + 16,
            top: (controller.showControlsState.value &&
                    !controller.lockControlsState.value)
                ? (padding.top > 0 ? padding.top + 8 : 12)
                : -(64 + padding.top),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: _FrostedBar(
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.15),
                    width: 0.8,
                  ),
                ),
                child: Row(
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () {
                      controller.exitCurrentFullScreenMode();
                    },
                    icon: const Icon(
                      Remix.fullscreen_exit_line,
                      color: Colors.white,
                      size: 20,
                    ),
                    tooltip: "退出全屏",
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "${controller.detail.value?.title ?? ''} - ${controller.detail.value?.userName ?? ''}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () {
                      controller.saveScreenshot();
                    },
                    icon: const Icon(
                      Icons.camera_alt_outlined,
                      color: Colors.white,
                      size: 20,
                    ),
                    tooltip: "截图",
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () {
                      showFollowUser(controller);
                    },
                    icon: const Icon(
                      Remix.play_list_2_line,
                      color: Colors.white,
                      size: 20,
                    ),
                    tooltip: "关注列表",
                  ),
                  Visibility(
                    visible: Platform.isAndroid,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      onPressed: () {
                        controller.enablePIP();
                      },
                      icon: const Icon(
                        Icons.picture_in_picture,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () {
                      showPlayerSettings(controller);
                    },
                    icon: const Icon(
                      Icons.more_horiz,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ],
                ),
              ),
            ),
          ),
        ),
        // 底部
        Obx(
          () => AnimatedPositioned(
            left: padding.left + 16,
            right: padding.right + 16,
            bottom: (controller.showControlsState.value &&
                    !controller.lockControlsState.value)
                ? (padding.bottom > 0 ? padding.bottom + 8 : 12)
                : -(64 + padding.bottom),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: _FrostedBar(
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.15),
                    width: 0.8,
                  ),
                ),
                child: Row(
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () {
                      controller.refreshRoom();
                    },
                    icon: const Icon(
                      Remix.refresh_line,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  Offstage(
                    offstage: controller.showDanmakuState.value,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      onPressed: () => controller.showDanmakuState.value =
                          !controller.showDanmakuState.value,
                      icon: const ImageIcon(
                        AssetImage('assets/icons/icon_danmaku_open.png'),
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Offstage(
                    offstage: !controller.showDanmakuState.value,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      onPressed: () => controller.showDanmakuState.value =
                          !controller.showDanmakuState.value,
                      icon: const ImageIcon(
                        AssetImage('assets/icons/icon_danmaku_close.png'),
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () {
                      showDanmakuSettings(controller);
                    },
                    icon: const ImageIcon(
                      AssetImage('assets/icons/icon_danmaku_setting.png'),
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                  Obx(
                    () => Padding(
                      padding: const EdgeInsets.only(left: 6.0),
                      child: Text(
                        controller.liveDuration.value,
                        style:
                            const TextStyle(fontSize: 12.5, color: Colors.white70),
                      ),
                    ),
                  ),
                  const Expanded(child: Center()),
                  Visibility(
                    visible: !Platform.isAndroid && !Platform.isIOS,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      key: volumeButtonkey,
                      onPressed: () {
                        controller
                            .showVolumeSlider(volumeButtonkey.currentContext!);
                      },
                      icon: const Icon(
                        Icons.volume_down,
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: () {
                      showQualitesInfo(controller);
                    },
                    child: Obx(
                      () => Text(
                        controller.currentQualityInfo.value,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: () {
                      showLinesInfo(controller);
                    },
                    child: Text(
                      controller.currentLineInfo.value,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () {
                      controller.exitCurrentFullScreenMode();
                    },
                    icon: const Icon(
                      Remix.fullscreen_exit_fill,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  ],
                ),
              ),
            ),
          ),
        ),

        // 右侧锁定 (仅移动端显示)
        Visibility(
          visible: Platform.isAndroid || Platform.isIOS,
          child: Obx(
            () => AnimatedPositioned(
              top: 0,
              bottom: 0,
              right: controller.showControlsState.value
                  ? padding.right + 12
                  : -(64 + padding.right),
              duration: const Duration(milliseconds: 200),
              child: buildLockButton(controller),
            ),
          ),
        ),
        // 左侧锁定 (仅移动端显示)
        Visibility(
          visible: Platform.isAndroid || Platform.isIOS,
          child: Obx(
            () => AnimatedPositioned(
              top: 0,
              bottom: 0,
              left: controller.showControlsState.value
                  ? padding.left + 12
                  : -(64 + padding.right),
              duration: const Duration(milliseconds: 200),
              child: buildLockButton(controller),
            ),
          ),
        ),
        Obx(
          () => Offstage(
            offstage: !controller.showGestureTip.value,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade900,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  controller.gestureTipText.value,
                  style: const TextStyle(fontSize: 18, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
    ),
  );
}

/// 全屏播放器键盘快捷键处理（仅桌面端全屏态生效）
/// - Space：显示/隐藏控制器
/// - F / Esc：退出全屏
/// - ↑/↓：音量±5
/// - M：静音切换
/// - C：弹幕开关
/// - R：刷新
/// - S：截图
/// - ←/→：上/下一条线路
/// - Q：循环清晰度
/// - 1-9：直接切到对应线路
KeyEventResult _onPlayerKeyEvent(
  KeyEvent event,
  LiveRoomController controller,
) {
  if (event is! KeyDownEvent || !controller.fullScreenState.value) {
    return KeyEventResult.ignored;
  }
  final key = event.logicalKey;

  if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.keyF) {
    controller.exitCurrentFullScreenMode();
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.space) {
    controller.onTap();
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyR) {
    controller.refreshRoom();
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyM) {
    controller.toggleMute();
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyC) {
    controller.showDanmakuState.value = !controller.showDanmakuState.value;
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyS) {
    controller.saveScreenshot();
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.arrowUp) {
    controller.adjustVolume(5);
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.arrowDown) {
    controller.adjustVolume(-5);
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.arrowRight) {
    _changePlayLine(controller, 1);
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.arrowLeft) {
    _changePlayLine(controller, -1);
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyQ) {
    _cycleQuality(controller);
    return KeyEventResult.handled;
  }
  final digit = _digitFromKey(key);
  if (digit != null) {
    final idx = digit - 1;
    if (idx >= 0 && idx < controller.playUrls.length) {
      controller.changePlayLine(idx);
      return KeyEventResult.handled;
    }
  }
  return KeyEventResult.ignored;
}

int? _digitFromKey(LogicalKeyboardKey key) {
  const digits = <LogicalKeyboardKey>[
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  const numpad = <LogicalKeyboardKey>[
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
    LogicalKeyboardKey.numpad6,
    LogicalKeyboardKey.numpad7,
    LogicalKeyboardKey.numpad8,
    LogicalKeyboardKey.numpad9,
  ];
  for (var i = 0; i < digits.length; i++) {
    if (key == digits[i] || key == numpad[i]) return i + 1;
  }
  return null;
}

void _changePlayLine(LiveRoomController controller, int delta) {
  final urls = controller.playUrls;
  if (urls.isEmpty) return;
  int next = controller.currentLineIndex + delta;
  if (next < 0) next += urls.length;
  if (next >= urls.length) next -= urls.length;
  controller.changePlayLine(next);
}

void _cycleQuality(LiveRoomController controller) {
  if (controller.qualites.isEmpty) return;
  int next = controller.currentQuality + 1;
  if (next >= controller.qualites.length) next = 0;
  controller.currentQuality = next;
  controller.getPlayUrl();
}

/// 毛玻璃胶囊容器：ClipRRect + BackdropFilter 模糊背后内容
/// - 用于全屏播放器顶部/底部控制条，营造 macOS 原生 vibrancy 观感
class _FrostedBar extends StatelessWidget {
  final Widget child;
  const _FrostedBar({required this.child});
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: child,
      ),
    );
  }
}

Widget buildLockButton(LiveRoomController controller) {
  return Center(
    child: InkWell(
      onTap: () {
        controller.setLockState();
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black45,
          borderRadius: AppStyle.radius8,
        ),
        width: 40,
        height: 40,
        child: Center(
          child: Icon(
            controller.lockControlsState.value
                ? Icons.lock_outline_rounded
                : Icons.lock_open_outlined,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    ),
  );
}

Widget buildControls(
  bool isPortrait,
  VideoState videoState,
  LiveRoomController controller,
) {
  GlobalKey volumeButtonkey = GlobalKey();
  return Stack(
    children: [
      Container(),
      buildDanmuView(videoState, controller),

      // 左下角SC显示
      Obx(
        () => Visibility(
          visible: AppSettingsController.instance.playershowSuperChat.value &&
              ((!Platform.isAndroid && !Platform.isIOS) ||
                  controller.fullScreenState.value),
          child: Positioned(
            left: 24,
            bottom: 24,
            child: PlayerSuperChatOverlay(controller: controller),
          ),
        ),
      ),

      // 中间
      Center(
        child: PlayerBufferingIndicator(
          controller: videoState.widget.controller,
        ),
      ),
      Positioned.fill(
        child: GestureDetector(
          onTap: controller.onTap,
          onDoubleTapDown: controller.onDoubleTap,
          onVerticalDragStart: controller.onVerticalDragStart,
          onVerticalDragUpdate: controller.onVerticalDragUpdate,
          onVerticalDragEnd: controller.onVerticalDragEnd,
          //onLongPress: controller.showDebugInfo,
          child: MouseRegion(
            onEnter: controller.onEnter,
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: Colors.transparent,
            ),
          ),
        ),
      ),
      Obx(
        () => AnimatedPositioned(
          left: 12,
          right: 12,
          bottom: controller.showControlsState.value ? 12 : -64,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.72),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withOpacity(0.15),
                width: 0.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                )
              ],
            ),
            child: Row(
              children: [
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: () {
                    controller.refreshRoom();
                  },
                  icon: const Icon(
                    Remix.refresh_line,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                Offstage(
                  offstage: controller.showDanmakuState.value,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () => controller.showDanmakuState.value =
                        !controller.showDanmakuState.value,
                    icon: const ImageIcon(
                      AssetImage('assets/icons/icon_danmaku_open.png'),
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
                Offstage(
                  offstage: !controller.showDanmakuState.value,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () => controller.showDanmakuState.value =
                        !controller.showDanmakuState.value,
                    icon: const ImageIcon(
                      AssetImage('assets/icons/icon_danmaku_close.png'),
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: () {
                    controller.showDanmuSettingsSheet();
                  },
                  icon: const ImageIcon(
                    AssetImage('assets/icons/icon_danmaku_setting.png'),
                    size: 20,
                    color: Colors.white,
                  ),
                ),
                Obx(
                  () => Padding(
                    padding: const EdgeInsets.only(left: 6.0),
                    child: Text(
                      controller.liveDuration.value,
                      style:
                          const TextStyle(fontSize: 12.5, color: Colors.white70),
                    ),
                  ),
                ),
                const Expanded(child: Center()),
                Visibility(
                  visible: !Platform.isAndroid && !Platform.isIOS,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    key: volumeButtonkey,
                    onPressed: () {
                      controller.showVolumeSlider(
                        volumeButtonkey.currentContext!,
                      );
                    },
                    icon: const Icon(
                      Icons.volume_down,
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
                Offstage(
                  offstage: isPortrait,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: () {
                      controller.showQualitySheet();
                    },
                    child: Obx(
                      () => Text(
                        controller.currentQualityInfo.value,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                  ),
                ),
                Offstage(
                  offstage: isPortrait,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: () {
                      controller.showPlayUrlsSheet();
                    },
                    child: Text(
                      controller.currentLineInfo.value,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
                Visibility(
                  visible: !Platform.isAndroid && !Platform.isIOS,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () {
                      controller.enterSmallWindow();
                    },
                    icon: const Icon(
                      Icons.picture_in_picture,
                      color: Colors.white,
                      size: 20,
                    ),
                    tooltip: "画中画/小窗",
                  ),
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onPressed: () {
                    controller.enterFullScreen();
                  },
                  icon: const Icon(
                    Remix.fullscreen_line,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      Obx(
        () => Offstage(
          offstage: !controller.showGestureTip.value,
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade900,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                controller.gestureTipText.value,
                style: const TextStyle(fontSize: 18, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

Widget buildDanmuView(VideoState videoState, LiveRoomController controller) {
  var padding = MediaQuery.of(videoState.context).padding;
  controller.danmakuView ??= DanmakuScreen(
    key: controller.globalDanmuKey,
    createdController: controller.initDanmakuController,
    option: DanmakuOption(
      fontSize: AppSettingsController.instance.danmuSize.value,
      area: AppSettingsController.instance.danmuArea.value,
      duration: AppSettingsController.instance.danmuSpeed.value.toInt(),
      opacity: AppSettingsController.instance.danmuOpacity.value,
      //strokeWidth: AppSettingsController.instance.danmuStrokeWidth.value,
      fontWeight: AppSettingsController.instance.danmuFontWeight.value,
    ),
  );
  return Positioned.fill(
    top: padding.top,
    bottom: padding.bottom,
    child: Obx(
      () => Offstage(
        offstage: !controller.showDanmakuState.value,
        child: Padding(
          padding: controller.fullScreenState.value
              ? EdgeInsets.only(
                  top: AppSettingsController.instance.danmuTopMargin.value,
                  bottom:
                      AppSettingsController.instance.danmuBottomMargin.value,
                )
              : EdgeInsets.zero,
          child: RepaintBoundary(
            child: controller.danmakuView!,
          ),
        ),
      ),
    ),
  );
}

void showLinesInfo(LiveRoomController controller) {
  if (controller.isVertical.value) {
    controller.showPlayUrlsSheet();
    return;
  }
  Utils.showRightDialog(
    title: "线路",
    useSystem: true,
    child: ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: controller.playUrls.length,
      itemBuilder: (_, i) {
        return ListTile(
          selected: controller.currentLineIndex == i,
          title: Text.rich(
            TextSpan(
              text: "线路${i + 1}",
              children: [
                WidgetSpan(
                    child: Container(
                  decoration: BoxDecoration(
                    borderRadius: AppStyle.radius4,
                    border: Border.all(
                      color: Colors.grey,
                    ),
                  ),
                  padding: AppStyle.edgeInsetsH4,
                  margin: AppStyle.edgeInsetsL8,
                  child: Text(
                    controller.playUrls[i].contains(".flv") ? "FLV" : "HLS",
                    style: const TextStyle(
                      fontSize: 12,
                    ),
                  ),
                )),
              ],
            ),
            style: const TextStyle(fontSize: 14),
          ),
          minLeadingWidth: 16,
          onTap: () {
            Utils.hideRightDialog();
            //controller.currentLineIndex = i;
            //controller.setPlayer();
            controller.changePlayLine(i);
          },
        );
      },
    ),
  );
}

void showQualitesInfo(LiveRoomController controller) {
  if (controller.isVertical.value) {
    controller.showQualitySheet();
    return;
  }
  Utils.showRightDialog(
    title: "清晰度",
    useSystem: true,
    child: ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: controller.qualites.length,
      itemBuilder: (_, i) {
        var item = controller.qualites[i];
        return ListTile(
          selected: controller.currentQuality == i,
          title: Text(
            item.quality,
            style: const TextStyle(fontSize: 14),
          ),
          minLeadingWidth: 16,
          onTap: () {
            Utils.hideRightDialog();
            controller.currentQuality = i;
            controller.getPlayUrl();
          },
        );
      },
    ),
  );
}

void showDanmakuSettings(LiveRoomController controller) {
  if (controller.isVertical.value) {
    controller.showDanmuSettingsSheet();
    return;
  }
  Utils.showRightDialog(
    title: "弹幕设置",
    width: 400,
    useSystem: true,
    child: ListView(
      padding: AppStyle.edgeInsetsA12,
      children: [
        DanmuSettingsView(
          danmakuController: controller.danmakuController,
        ),
      ],
    ),
  );
}

void showPlayerSettings(LiveRoomController controller) {
  if (controller.isVertical.value) {
    controller.showPlayerSettingsSheet();
    return;
  }
  Utils.showRightDialog(
    title: "设置",
    width: 320,
    useSystem: true,
    child: Obx(
      () => RadioGroup(
        groupValue: AppSettingsController.instance.scaleMode.value,
        onChanged: (e) {
          AppSettingsController.instance.setScaleMode(e ?? 0);
          controller.updateScaleMode();
        },
        child: ListView(
          padding: AppStyle.edgeInsetsV12,
          children: [
            Padding(
              padding: AppStyle.edgeInsetsH16,
              child: Text(
                "画面尺寸",
                style: Get.textTheme.titleMedium,
              ),
            ),
            const RadioListTile(
              value: 0,
              contentPadding: AppStyle.edgeInsetsH4,
              title: Text("适应"),
              visualDensity: VisualDensity.compact,
            ),
            const RadioListTile(
              value: 1,
              contentPadding: AppStyle.edgeInsetsH4,
              title: Text("拉伸"),
              visualDensity: VisualDensity.compact,
            ),
            const RadioListTile(
              value: 2,
              contentPadding: AppStyle.edgeInsetsH4,
              title: Text("铺满"),
              visualDensity: VisualDensity.compact,
            ),
            const RadioListTile(
              value: 3,
              contentPadding: AppStyle.edgeInsetsH4,
              title: Text("16:9"),
              visualDensity: VisualDensity.compact,
            ),
            const RadioListTile(
              value: 4,
              contentPadding: AppStyle.edgeInsetsH4,
              title: Text("4:3"),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    ),
  );
}

void showFollowUser(LiveRoomController controller) {
  if (controller.isVertical.value) {
    controller.showFollowUserSheet();
    return;
  }

  Utils.showRightDialog(
    title: "关注列表",
    width: 400,
    useSystem: true,
    child: Obx(
      () => Stack(
        children: [
          RefreshIndicator(
            onRefresh: FollowService.instance.loadData,
            child: ListView.builder(
              itemCount: FollowService.instance.liveList.length,
              itemBuilder: (_, i) {
                var item = FollowService.instance.liveList[i];
                return Obx(
                  () => FollowUserItem(
                    item: item,
                    playing: controller.rxSite.value.id == item.siteId &&
                        controller.rxRoomId.value == item.roomId,
                    onTap: () {
                      Utils.hideRightDialog();
                      controller.resetRoom(
                        Sites.allSites[item.siteId]!,
                        item.roomId,
                      );
                    },
                  ),
                );
              },
            ),
          ),
          if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
            Positioned(
              right: 12,
              bottom: 12,
              child: Obx(
                () => DesktopRefreshButton(
                  refreshing: FollowService.instance.updating.value,
                  onPressed: FollowService.instance.loadData,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class PlayerSuperChatCard extends StatefulWidget {
  final LiveSuperChatMessage message;
  final VoidCallback onExpire;
  final int duration;
  const PlayerSuperChatCard(
      {required this.message,
      required this.onExpire,
      required this.duration,
      Key? key})
      : super(key: key);
  @override
  State<PlayerSuperChatCard> createState() => _PlayerSuperChatCardState();
}

class _PlayerSuperChatCardState extends State<PlayerSuperChatCard> {
  late Timer timer;
  late int countdown;
  @override
  void initState() {
    super.initState();
    countdown = widget.duration;
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (countdown <= 1) {
        widget.onExpire();
        timer.cancel();
        return;
      }
      setState(() {
        countdown -= 1;
      });
    });
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.65,
      child: SuperChatCard(
        widget.message,
        onExpire: () {},
        customCountdown: countdown,
      ),
    );
  }
}

class LocalDisplaySC {
  final LiveSuperChatMessage sc;
  final DateTime expireAt;
  final int duration;
  LocalDisplaySC(this.sc, this.expireAt, this.duration);
}

class PlayerSuperChatOverlay extends StatefulWidget {
  final LiveRoomController controller;
  const PlayerSuperChatOverlay({required this.controller, Key? key})
      : super(key: key);
  @override
  State<PlayerSuperChatOverlay> createState() => _PlayerSuperChatOverlayState();
}

class _PlayerSuperChatOverlayState extends State<PlayerSuperChatOverlay> {
  final List<LocalDisplaySC> _displayed = [];
  final Map<LocalDisplaySC, Timer> _timers = {};
  late Worker _worker;

  void _addSC(LiveSuperChatMessage sc, {int? customSeconds}) {
    if (_displayed.any((e) => e.sc == sc)) return;
    int showSeconds = customSeconds ?? 15;
    final expireAt = DateTime.now().add(Duration(seconds: showSeconds));
    final localSC = LocalDisplaySC(sc, expireAt, showSeconds);
    _displayed.add(localSC);
    _timers[localSC] = Timer(Duration(seconds: showSeconds), () {
      setState(() {
        _displayed.remove(localSC);
        _timers.remove(localSC)?.cancel();
      });
    });
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    // 首次进房时同步已有SC
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var sc in widget.controller.superChats) {
      int remain = (sc.endTime.millisecondsSinceEpoch - now) ~/ 1000;
      if (remain > 0) {
        _addSC(sc, customSeconds: remain < 15 ? remain : 15);
      }
    }
    // 监听SC列表变化
    _worker =
        ever<List<LiveSuperChatMessage>>(widget.controller.superChats, (list) {
      // 新增
      for (var sc in list) {
        if (!_displayed.any((e) => e.sc == sc)) {
          _addSC(sc);
        }
      }
      // 移除
      _displayed.removeWhere((e) => !list.contains(e.sc));
      setState(() {});
    });
  }

  @override
  void dispose() {
    _worker.dispose();
    for (var t in _timers.values) {
      t.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _displayed.toList()
      ..sort((a, b) => a.sc.endTime.compareTo(b.sc.endTime));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var localSC in sorted)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              width: 240,
              child: PlayerSuperChatCard(
                message: localSC.sc,
                onExpire: () {},
                duration: localSC.duration,
              ),
            ),
          ),
      ],
    );
  }
}

/// 播放器缓冲指示器
/// 抽成独立 StatefulWidget：在 initState 中缓存 stream 引用，
/// 避免父级 Obx 重建时 StreamBuilder 反复重新订阅。
class PlayerBufferingIndicator extends StatefulWidget {
  final VideoController controller;
  final WidgetBuilder? indicator;

  const PlayerBufferingIndicator({
    super.key,
    required this.controller,
    this.indicator,
  });

  @override
  State<PlayerBufferingIndicator> createState() =>
      _PlayerBufferingIndicatorState();
}

class _PlayerBufferingIndicatorState extends State<PlayerBufferingIndicator> {
  late final Stream<bool> _stream;
  late final bool _initial;

  @override
  void initState() {
    super.initState();
    _stream = widget.controller.player.stream.buffering;
    _initial = widget.controller.player.state.buffering;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: _stream,
      initialData: _initial,
      builder: (_, s) => Visibility(
        visible: s.data ?? false,
        child: Center(
          child: widget.indicator?.call(context) ??
              const CupertinoActivityIndicator(),
        ),
      ),
    );
  }
}
