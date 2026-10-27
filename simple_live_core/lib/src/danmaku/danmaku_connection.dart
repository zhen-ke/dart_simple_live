import 'package:simple_live_core/src/common/web_socket_util.dart';

/// 弹幕连接的生命周期所有者。
///
/// 约束：一个弹幕实例在任意时刻最多持有一条 WebSocket。
/// 各平台实现不再直接给 `webScoketUtils` 赋值，而是统一走
/// [replaceConnection] —— 关闭旧连接、接管新连接、发起连接三步原子完成。
///
/// 这样"未 stop 就再次 start"不会留下仍在推流的旧连接
/// （重复弹幕、旧心跳与旧重连定时器常驻），新平台实现也不会漏。
mixin DanmakuConnection {
  WebScoketUtils? webScoketUtils;

  /// 接管一条新连接，并保证旧连接被关闭
  void replaceConnection(WebScoketUtils next) {
    webScoketUtils?.close();
    webScoketUtils = next;
    next.connect();
  }

  /// 关闭并释放当前连接（stop/dispose 时调用）
  void closeConnection() {
    webScoketUtils?.close();
    webScoketUtils = null;
  }
}
