import 'dart:async';

import 'package:flutter/painting.dart';

/// 图片内存缓存策略。
///
/// 退出直播间时既不能像旧版那样无条件 `clear()`——房间头像/SC 图片与
/// 首页、关注、历史列表共用同一份缓存键，全局清空会让返回列表全部
/// 重下；也不能完全不管——`maximumSizeBytes` 允许最多 50MB 解码图常驻。
///
/// 做法是两级回收：
/// 1. 等路由退出动画结束（页面真正从树上移除）后 `clearLiveImages()`，
///    只回收"已无 widget 引用"的图——房间里的 SC 大图、头像正好在这一类，
///    列表页仍在使用的封面不受影响；
/// 2. 若回收后仍超过预算，再整体 `clear()` 兜底。
class ImageCachePolicy {
  ImageCachePolicy._();

  /// 退出直播间时的回收阈值。
  /// 32MB 大致相当于 20–30 张列表封面；超过它说明房间里的头像/SC 图
  /// 已经占了大头，继续留着对返回列表的命中率贡献有限。
  static const int exitTrimThresholdBytes = 32 * 1024 * 1024;

  /// 路由退出动画的余量：动画结束后页面元素才真正卸载，
  /// 此时它的图片才从 live 变成可回收
  static const Duration _routeExitGrace = Duration(milliseconds: 400);

  static ImageCache get _cache => PaintingBinding.instance.imageCache;

  /// 退出直播间时调用：延迟到退场动画结束后按预算回收
  static void trimOnRoomExit() {
    unawaited(
      Future<void>.delayed(_routeExitGrace, () {
        _cache.clearLiveImages();
        if (_cache.currentSizeBytes <= exitTrimThresholdBytes) return;
        _cache.clear();
      }),
    );
  }

  /// 系统内存压力回调：无条件释放。这是 OS 的明确信号，
  /// 此时保缓存换来的体验远不如避免被系统杀掉
  static void trimOnMemoryPressure() {
    _cache.clear();
  }
}
