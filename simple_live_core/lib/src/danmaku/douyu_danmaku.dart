import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show Endian;

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/danmaku_decode_worker.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';

import '../common/binary_writer.dart';
import 'danmaku_connection.dart';

class DouyuDanmaku with DanmakuConnection implements LiveDanmaku {
  @override
  int heartbeatTime = 45 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://danmuproxy.douyu.com:8506";

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
    replaceConnection(WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        onReady?.call();
        joinRoom(args);
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
    ));
  }

  void joinRoom(roomId) {
    webScoketUtils
        ?.sendMessage(serializeDouyu("type@=loginreq/roomid@=$roomId/"));
    webScoketUtils?.sendMessage(
        serializeDouyu("type@=joingroup/rid@=$roomId/gid@=-9999/"));
  }

  @override
  void heartbeat() {
    var data = serializeDouyu("type@=mrkl/");
    webScoketUtils?.sendMessage(data);
  }

  @override
  Future stop() async {
    _startGeneration++;
    onMessage = null;
    onClose = null;
    closeConnection();
    _decoderWorker?.dispose();
    _decoderWorker = null;
  }

  void decodeMessage(List<int> data) {
    final generation = _startGeneration;
    final wallTime = Stopwatch()..start();
    final decoder = _decoderWorker ??= DanmakuDecodeWorker();
    unawaited(
      decoder.decodeDouyu(data).then<void>((decoded) {
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
          if (raw['kind'] == 'chat') {
            onMessage?.call(
              LiveMessage(
                type: LiveMessageType.chat,
                userName: raw['userName'].toString(),
                message: raw['message'].toString(),
                color: getColor((raw['colorType'] as num?)?.toInt() ?? 0),
              ),
            );
          }
        }
      }).catchError((Object error, StackTrace stackTrace) {
        wallTime.stop();
        if (generation == _startGeneration) CoreLog.error(error);
      }),
    );
  }

  List<int> serializeDouyu(String body) {
    try {
      const int clientSendToServer = 689;
      const int encrypted = 0;
      const int reserved = 0;

      List<int> buffer = utf8.encode(body);

      var writer = BinaryWriter([]);
      writer.writeInt(4 + 4 + body.length + 1, 4, endian: Endian.little);
      writer.writeInt(4 + 4 + body.length + 1, 4, endian: Endian.little);
      writer.writeInt(clientSendToServer, 2, endian: Endian.little);
      writer.writeInt(encrypted, 1, endian: Endian.little);
      writer.writeInt(reserved, 1, endian: Endian.little);
      writer.writeBytes(buffer);
      writer.writeInt(0, 1, endian: Endian.little);
      return writer.buffer;
    } catch (e) {
      CoreLog.error(e);
      return [];
    }
  }

  LiveMessageColor getColor(int type) {
    switch (type) {
      case 1:
        return LiveMessageColor(255, 0, 0);
      case 2:
        return LiveMessageColor(30, 135, 240);
      case 3:
        return LiveMessageColor(122, 200, 75);
      case 4:
        return LiveMessageColor(255, 127, 0);
      case 5:
        return LiveMessageColor(155, 57, 244);
      case 6:
        return LiveMessageColor(255, 105, 180);
      default:
        return LiveMessageColor.white;
    }
  }
}
