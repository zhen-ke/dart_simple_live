import 'dart:async';

import 'package:simple_live_core/src/model/live_message.dart';

class LiveDanmaku {
  Function(LiveMessage msg)? onMessage;
  Function(String msg)? onClose;
  Function()? onReady;

  /// 心跳时间
  int heartbeatTime = 0;

  /// 发生心跳
  void heartbeat() {}

  /// 开始接收信息
  /// - [args] 为各平台的弹幕参数对象（见 LiveRoomDetail.danmakuData）。
  ///   允许传入仍在解析中的 Future：详情先返回让视频起播，
  ///   弹幕参数并行解析，实现方在连接前 await 其完成
  Future start(FutureOr<Object?> args) {
    return Future.value();
  }

  /// 停止接收信息
  Future stop() {
    return Future.value();
  }
}
