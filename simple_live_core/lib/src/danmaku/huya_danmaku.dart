import 'dart:async';
import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/danmaku_decode_worker.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';

class HuyaDanmakuArgs {
  final int ayyuid;
  final int topSid;
  final int subSid;
  HuyaDanmakuArgs({
    required this.ayyuid,
    required this.topSid,
    required this.subSid,
  });
  @override
  String toString() {
    return json.encode({
      "ayyuid": ayyuid,
      "topSid": topSid,
      "subSid": subSid,
    });
  }
}

class HuyaDanmaku implements LiveDanmaku {
  @override
  int heartbeatTime = 60 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://cdnws.api.huya.com";

  WebScoketUtils? webScoketUtils;

  final heartbeatData = base64.decode("ABQdAAwsNgBM");

  late HuyaDanmakuArgs danmakuArgs;
  int _startGeneration = 0;
  DanmakuDecodeWorker? _decoderWorker;

  @override
  Future start(dynamic args) async {
    final startGeneration = ++_startGeneration;
    // danmakuData 允许传入在途 Future：连接前等待其就绪
    if (args is Future) {
      args = await args;
    }
    if (startGeneration != _startGeneration) return;
    danmakuArgs = args as HuyaDanmakuArgs;
    webScoketUtils = WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        onReady?.call();
        joinRoom();
      },
      onHeartBeat: () {
        heartbeat();
      },
      onReconnect: () {
        onClose?.call("与服务器断开连接，正在尝试重连");
      },
      onClose: (e) {
        onClose?.call("服务器连接失败$e");
      },
    );
    webScoketUtils?.connect();
  }

  void joinRoom() {
    var joinData =
        getJoinData(danmakuArgs.ayyuid, danmakuArgs.topSid, danmakuArgs.topSid);
    webScoketUtils?.sendMessage(joinData);
  }

  List<int> getJoinData(int ayyuid, int tid, int sid) {
    try {
      var oos = TarsOutputStream();
      oos.write(ayyuid, 0);
      oos.write(true, 1);
      oos.write("", 2);
      oos.write("", 3);
      oos.write(tid, 4);
      oos.write(sid, 5);
      oos.write(0, 6);
      oos.write(0, 7);

      var wscmd = TarsOutputStream();
      wscmd.write(1, 0);
      wscmd.write(oos.toUint8List(), 1);
      return wscmd.toUint8List();
    } catch (e) {
      CoreLog.error(e);
      return [];
    }
  }

  @override
  void heartbeat() {
    webScoketUtils?.sendMessage(heartbeatData);
  }

  @override
  Future stop() async {
    _startGeneration++;
    onMessage = null;
    onClose = null;
    webScoketUtils?.close();
    _decoderWorker?.dispose();
    _decoderWorker = null;
  }

  /// 收到WebSocket信息
  void decodeMessage(List<int> data) {
    final generation = _startGeneration;
    final wallTime = Stopwatch()..start();
    final decoder = _decoderWorker ??= DanmakuDecodeWorker();
    unawaited(
      decoder.decodeHuya(data).then<void>((decoded) {
        wallTime.stop();
        if (generation != _startGeneration) return;
        LiveMetrics.instance.recordDanmakuDecode(
          Duration(
            microseconds: (decoded['elapsedUs'] as num?)?.toInt() ?? 0,
          ),
          messageCount: (decoded['messageCount'] as num?)?.toInt() ?? 0,
          wallElapsed: wallTime.elapsed,
        );
        if (decoded['error'] != null) CoreLog.error(decoded['error']);
        for (final raw in decoded['messages'] as List? ?? const []) {
          if (raw is! Map) continue;
          switch (raw['kind']) {
            case 'chat':
              final color = (raw['color'] as num?)?.toInt() ?? 0;
              onMessage?.call(
                LiveMessage(
                  type: LiveMessageType.chat,
                  color: color <= 0
                      ? LiveMessageColor.white
                      : LiveMessageColor.numberToColor(color),
                  message: raw['message'].toString(),
                  userName: raw['userName'].toString(),
                ),
              );
              break;
            case 'online':
              onMessage?.call(
                LiveMessage(
                  type: LiveMessageType.online,
                  data: (raw['data'] as num?)?.toInt() ?? 0,
                  color: LiveMessageColor.white,
                  message: '',
                  userName: '',
                ),
              );
              break;
          }
        }
      }).catchError((Object error, StackTrace stackTrace) {
        wallTime.stop();
        if (generation == _startGeneration) CoreLog.error(error);
      }),
    );
  }
}
