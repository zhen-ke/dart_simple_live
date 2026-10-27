import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/danmaku_decode_worker.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';

import '../common/binary_writer.dart';
import 'danmaku_connection.dart';

class BiliBiliDanmakuArgs {
  final int roomId;
  final String token;
  final String buvid;
  final String serverHost;
  final int uid;
  final String cookie;
  BiliBiliDanmakuArgs({
    required this.roomId,
    required this.token,
    required this.serverHost,
    required this.buvid,
    required this.uid,
    required this.cookie,
  });
  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "token": token,
      "serverHost": serverHost,
      "buvid": buvid,
      "uid": uid,
      "cookie": cookie,
    });
  }
}

class BiliBiliDanmaku with DanmakuConnection implements LiveDanmaku {
  @override
  int heartbeatTime = 60 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;

  //String serverUrl = "wss://broadcastlv.chat.bilibili.com/sub";

  late BiliBiliDanmakuArgs danmakuArgs;
  int _startGeneration = 0;
  DanmakuDecodeWorker? _decoderWorker;
  @override
  Future start(dynamic args) async {
    final startGeneration = ++_startGeneration;
    // danmakuData 允许传入在途 Future：详情先返回让视频起播，
    // 弹幕参数并行解析，连接前等待其就绪
    if (args is Future) {
      args = await args;
    }
    if (startGeneration != _startGeneration) return;
    danmakuArgs = args as BiliBiliDanmakuArgs;
    replaceConnection(WebScoketUtils(
      url: "wss://${args.serverHost}/sub",
      heartBeatTime: heartbeatTime,
      headers: args.cookie.isEmpty
          ? null
          : {
              "cookie": args.cookie,
            },
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        onReady?.call();
        joinRoom(danmakuArgs);
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

  void joinRoom(BiliBiliDanmakuArgs args) {
    var joinData = encodeData(
      json.encode({
        "uid": args.uid,
        "roomid": args.roomId,
        "protover": 3,
        "buvid": args.buvid,
        "platform": "web",
        "type": 2,
        "key": args.token,
      }),
      7,
    );
    webScoketUtils?.sendMessage(joinData);
  }

  @override
  void heartbeat() {
    webScoketUtils?.sendMessage(encodeData(
      "",
      2,
    ));
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

  List<int> encodeData(String msg, int action) {
    var data = utf8.encode(msg);
    //头部长度固定16
    var length = data.length + 16;
    var buffer = Uint8List(length);

    var writer = BinaryWriter([]);

    //数据包长度
    writer.writeInt(buffer.length, 4);
    //数据包头部长度,固定16
    writer.writeInt(16, 2);

    //协议版本，0=JSON,1=Int32,2=Buffer
    writer.writeInt(0, 2);

    //操作类型
    writer.writeInt(action, 4);

    //数据包头部长度,固定1

    writer.writeInt(1, 4);

    writer.writeBytes(data);

    return writer.buffer;
  }

  void decodeMessage(List<int> data) {
    final generation = _startGeneration;
    final wallTime = Stopwatch()..start();
    final decoder = _decoderWorker ??= DanmakuDecodeWorker();
    unawaited(
      decoder.decodeBilibili(data).then<void>((decoded) {
        wallTime.stop();
        if (generation != _startGeneration) return;
        final elapsed = Duration(
          microseconds: (decoded['elapsedUs'] as num?)?.toInt() ?? 0,
        );
        final messages = decoded['messages'] as List? ?? const [];
        LiveMetrics.instance.recordDanmakuDecode(
          elapsed,
          messageCount: (decoded['messageCount'] as num?)?.toInt() ?? 0,
          wallElapsed: wallTime.elapsed,
        );
        if (decoded['error'] != null) CoreLog.error(decoded['error']);
        for (final raw in messages) {
          if (raw is! Map) continue;
          switch (raw['kind']) {
            case 'online':
              onMessage?.call(
                LiveMessage(
                  type: LiveMessageType.online,
                  data: raw['data'],
                  color: LiveMessageColor.white,
                  message: '',
                  userName: '',
                ),
              );
              break;
            case 'chat':
              final color = (raw['color'] as num?)?.toInt() ?? 0;
              onMessage?.call(
                LiveMessage(
                  type: LiveMessageType.chat,
                  userName: raw['userName'].toString(),
                  message: raw['message'].toString(),
                  color: color == 0
                      ? LiveMessageColor.white
                      : LiveMessageColor.numberToColor(color),
                ),
              );
              break;
            case 'superChat':
              final superChat = LiveSuperChatMessage(
                backgroundBottomColor:
                    raw['backgroundBottomColor'].toString(),
                backgroundColor: raw['backgroundColor'].toString(),
                endTime: DateTime.fromMillisecondsSinceEpoch(
                  (raw['endTimeMs'] as num).toInt(),
                ),
                face: raw['face'].toString(),
                message: raw['message'].toString(),
                price: (raw['price'] as num).toInt(),
                startTime: DateTime.fromMillisecondsSinceEpoch(
                  (raw['startTimeMs'] as num).toInt(),
                ),
                userName: raw['userName'].toString(),
              );
              onMessage?.call(
                LiveMessage(
                  type: LiveMessageType.superChat,
                  userName: 'SUPER_CHAT_MESSAGE',
                  message: 'SUPER_CHAT_MESSAGE',
                  color: LiveMessageColor.white,
                  data: superChat,
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
