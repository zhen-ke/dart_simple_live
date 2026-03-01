import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:window_manager/window_manager.dart';

/// 统一的系统控制服务
/// 用于隔离移动端与桌面端的系统API调用
class SystemControlService extends GetxService {
  static SystemControlService get instance => Get.find<SystemControlService>();

  bool get _isDesktopPlatform => Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  bool get _isMobilePlatform => Platform.isAndroid || Platform.isIOS;

  Future<SystemControlService> init() async {
    return this;
  }

  /// 获取系统音量 (0.0 - 1.0)
  Future<double> getVolume() async {
    if (_isMobilePlatform) {
      return await VolumeController.instance.getVolume();
    }
    // 桌面端通常由播放器自己管理音量，不读取系统全局音量
    return 1.0;
  }

  /// 设置系统音量 (0.0 - 1.0)
  Future<void> setVolume(double volume) async {
    if (_isMobilePlatform) {
      VolumeController.instance.setVolume(volume);
    }
    // 桌面端不做处理，音量由播放器自己调节
  }

  /// 隐藏或显示系统音量UI
  void setShowSystemVolumeUI(bool show) {
    if (_isMobilePlatform) {
      VolumeController.instance.showSystemUI = show;
    }
  }

  /// 是否支持亮度调节
  bool get supportBrightnessControl => _isMobilePlatform;

  /// 获取系统亮度 (0.0 - 1.0)
  Future<double> getBrightness() async {
    if (_isMobilePlatform) {
      return await ScreenBrightness.instance.application;
    }
    return 1.0;
  }

  /// 设置系统亮度 (0.0 - 1.0)
  Future<void> setBrightness(double brightness) async {
    if (_isMobilePlatform) {
      await ScreenBrightness.instance.setApplicationScreenBrightness(brightness);
    }
  }

  /// 重置系统亮度
  Future<void> resetBrightness() async {
    if (_isMobilePlatform) {
      try {
        await ScreenBrightness.instance.resetApplicationScreenBrightness();
      } catch (e) {
        debugPrint('Failed to reset brightness: $e');
      }
    }
  }

  /// 进入小窗模式 (桌面端伪画中画)
  Future<void> enterDesktopSmallWindow({
    required double videoWidth,
    required double videoHeight,
  }) async {
    if (!_isDesktopPlatform) return;

    // 读取窗口大小
    _lastWindowSize = await windowManager.getSize();
    _lastWindowPosition = await windowManager.getPosition();

    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);

    // 获取视频窗口大小
    var width = videoWidth > 0 ? videoWidth : 16.0;
    var height = videoHeight > 0 ? videoHeight : 9.0;

    // 横屏还是竖屏
    if (height > width) {
      var aspectRatio = width / height;
      await windowManager.setSize(Size(400, 400 / aspectRatio));
    } else {
      var aspectRatio = height / width;
      await windowManager.setSize(Size(280 / aspectRatio, 280));
    }

    await windowManager.setAlwaysOnTop(true);
  }

  Size? _lastWindowSize;
  Offset? _lastWindowPosition;

  /// 退出小窗模式 (桌面端)
  Future<void> exitDesktopSmallWindow() async {
    if (!_isDesktopPlatform) return;

    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    if (_lastWindowSize != null) {
      await windowManager.setSize(_lastWindowSize!);
    }
    if (_lastWindowPosition != null) {
      await windowManager.setPosition(_lastWindowPosition!);
    }
    await windowManager.setAlwaysOnTop(false);
  }
}
