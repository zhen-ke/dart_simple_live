import 'dart:async';
import 'dart:math';

import 'package:web_socket_channel/io.dart';

enum SocketStatus {
  connected,
  failed,
  closed,
}

class WebScoketUtils {
  SocketStatus status = SocketStatus.closed;

  /// 链接
  final String url;

  /// 备用链接
  final String? backupUrl;

  /// 心跳时间
  final int heartBeatTime;

  /// 接收到信息
  final Function(dynamic)? onMessage;

  /// 连接关闭
  final Function(String msg)? onClose;

  /// 尝试重连
  final Function()? onReconnect;

  /// 准备就绪
  final Function()? onReady;

  /// 心跳
  final Function()? onHeartBeat;

  /// 请求头
  Map<String, dynamic>? headers;
  WebScoketUtils({
    required this.url,
    required this.heartBeatTime,
    this.onMessage,
    this.onClose,
    this.onReconnect,
    this.onReady,
    this.onHeartBeat,
    this.headers,
    this.backupUrl,
  });
  IOWebSocketChannel? webSocket;
  Timer? heartBeatTimer;

  /// 重连次数
  int reconnectTime = 0;
  Timer? reconnectTimer;

  /// 最大重连次数
  int maxReconnectTime = 5;

  /// 重连退避上限
  static const int _maxBackoffMs = 30000;

  StreamSubscription<dynamic>? streamSubscription;

  /// 连接代次：每次发起连接或主动关闭时递增。
  /// 过期的握手完成/失败回调据此丢弃，防止已 close 的
  /// 连接在异步返回后复活状态、重启心跳。
  int _connectGen = 0;

  /// 是否为主动关闭：主动关闭后不再安排任何重连
  bool _closedByUser = false;

  final Random _random = Random();

  void connect({bool retry = false}) async {
    _closedByUser = false;
    final gen = ++_connectGen;
    _teardownChannel();
    try {
      var wsurl = url;
      if (backupUrl != null && backupUrl!.isNotEmpty && retry) {
        wsurl = backupUrl!;
      }
      final channel = IOWebSocketChannel.connect(
        wsurl,
        connectTimeout: const Duration(seconds: 10),
        headers: headers,
      );
      webSocket = channel;

      await channel.ready;
      // 握手期间连接可能被主动关闭或被更新的连接取代
      if (gen != _connectGen) {
        await channel.sink.close();
        return;
      }
      _onChannelReady(channel);
    } catch (_) {
      if (gen != _connectGen) return;
      // 首选地址失败后换备用地址再试一次，仍失败交给统一重连调度
      if (!retry && backupUrl != null && backupUrl!.isNotEmpty) {
        connect(retry: true);
        return;
      }
      _scheduleReconnect();
    }
  }

  /// 连接完成
  void _onChannelReady(IOWebSocketChannel channel) {
    status = SocketStatus.connected;

    streamSubscription = channel.stream.listen(
      (data) => receiveMessage(data),
      onError: (e, s) => _onChannelDropped(),
      onDone: _onChannelDropped,
    );

    onReady?.call();
    initHeartBeat();
  }

  void initHeartBeat() {
    heartBeatTimer = Timer.periodic(
      Duration(milliseconds: heartBeatTime),
      (timer) {
        onHeartBeat?.call();
      },
    );
  }

  void receiveMessage(dynamic data) {
    //接受到一条信息才算重连成功
    reconnectTime = 0;
    onMessage?.call(data);
  }

  /// 已建立的连接被服务端断开或读取出错：
  /// 统一交给重连调度，而不是各路径自行处理
  void _onChannelDropped() {
    if (status != SocketStatus.connected) {
      return;
    }
    _teardownChannel();
    status = SocketStatus.closed;
    _scheduleReconnect();
  }

  /// 统一重连调度：连接失败、连接后断开都走这里。
  /// 指数退避 + 随机抖动，避免多客户端齐步重连
  void _scheduleReconnect() {
    if (_closedByUser) return;
    if (reconnectTime >= maxReconnectTime) {
      status = SocketStatus.failed;
      onClose?.call("重连超过最大次数，与服务器断开连接");
      return;
    }
    reconnectTime++;
    onReconnect?.call();
    final backoff = min(2000 * (1 << (reconnectTime - 1)), _maxBackoffMs);
    reconnectTimer?.cancel();
    reconnectTimer = Timer(
      Duration(milliseconds: backoff + _random.nextInt(1000)),
      () => connect(),
    );
  }

  void sendMessage(dynamic message) {
    if (status == SocketStatus.connected) {
      webSocket?.sink.add(message);
    }
  }

  /// 释放当前通道，不影响重连调度
  void _teardownChannel() {
    // 取消订阅与关闭 sink 都是"发完就不管"的清理动作，
    // 但必须显式表达忽略，避免与真正的漏 await 混在一起
    unawaited(streamSubscription?.cancel());
    streamSubscription = null;

    heartBeatTimer?.cancel();
    heartBeatTimer = null;

    unawaited(webSocket?.sink.close());
    webSocket = null;
  }

  /// 主动关闭：终止一切重连，并使在飞的握手回调失效
  void close() {
    _closedByUser = true;
    _connectGen++;

    reconnectTimer?.cancel();
    reconnectTimer = null;

    _teardownChannel();
    status = SocketStatus.closed;
  }
}
