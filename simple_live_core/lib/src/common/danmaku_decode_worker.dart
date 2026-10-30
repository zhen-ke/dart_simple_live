import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:brotli/brotli.dart';
import 'package:simple_live_core/src/danmaku/proto/douyin.pb.dart';
import 'package:simple_live_core/src/model/tars/huya_danmaku.dart';
// tars_dart 里有一个同名 BinaryReader，这里只用 core 自己的实现
import 'package:tars_dart/tars/codec/tars_input_stream.dart' hide BinaryReader;

import 'binary_writer.dart';
import 'core_log.dart';
import 'live_metrics.dart';

/// 一帧待解码数据的生命周期载体。
///
/// 排队、在途、完成三个阶段共用同一份状态：`payload` 在真正投递给
/// 子 isolate 后立即置空，避免主 isolate 在队列里长期持有一份原始帧。
class _PendingFrame {
  _PendingFrame(this.id, this.platform, this.payload)
      : size = payload.lengthInBytes;

  static final Uint8List _empty = Uint8List(0);

  final int id;
  final String platform;
  final int size;
  Uint8List payload;

  final Completer<Map<String, dynamic>> completer =
      Completer<Map<String, dynamic>>();

  /// 字节已转移给子 isolate，主 isolate 不再持有
  void releasePayload() => payload = _empty;

  void completeWith(Map<String, dynamic> value) {
    if (!completer.isCompleted) completer.complete(value);
  }

  void completeError(Object error) {
    if (!completer.isCompleted) completer.completeError(error);
  }
}

/// Long-lived decoder isolate for the hot Bilibili/Douyin/Huya/Douyu frame
/// paths. Keeping one worker per room avoids paying Isolate.run's spawn cost
/// for every frame while preserving frame order.
///
/// 定位：Isolate 只是"加速器"，不是"唯一通路"。
/// - 监听退出/错误端口，退出时失败全部在途请求并复位状态；
/// - 崩溃后按指数退避重新拉起，退避窗口内改在调用方 isolate 内联解码，
///   保证弹幕永远不会因为解码器崩溃而停摆（只是短暂占用 UI 线程）。
///
/// 内存边界（这是本类存在的第二个理由）：
/// 调用方是 `unawaited` 逐帧投递的，WebSocket 不会等解码完成再收下一帧。
/// 如果这里不设上限，解码慢于到达时待处理帧会无限堆积——每帧还会在
/// 主 isolate 与子 isolate 各留一份。所以这里是一条**有界流水线**：
/// - 排队区最多 [maxQueuedFrames] 帧 / [maxQueuedBytes] 字节，满了丢最旧的；
/// - 子 isolate 同时最多 [maxInFlightFrames] 帧，天然限制延迟；
/// - 帧字节用 [TransferableTypedData] 转移，投递后主 isolate 立刻释放。
class DanmakuDecodeWorker {
  /// 排队上限：解码跟不上时保新弃旧，内存与延迟都被这两个上限锁死
  static const int maxQueuedFrames = 32;
  static const int maxQueuedBytes = 4 * 1024 * 1024;

  /// 子 isolate 在途窗口：越小积压越少，帧顺序仍由排队区保证
  static const int maxInFlightFrames = 4;

  ReceivePort? _receivePort;
  ReceivePort? _exitPort;
  ReceivePort? _errorPort;
  Isolate? _isolate;
  SendPort? _sendPort;
  Future<void>? _startTask;
  Completer<SendPort>? _readyCompleter;
  int _nextRequestId = 0;
  bool _disposed = false;

  /// 解码 Isolate 代次：每次启动/复位递增，用于丢弃旧 Isolate 的迟到回调
  int _workerGen = 0;

  /// 连续失败次数：决定重新拉起的退避时长
  int _failureStreak = 0;

  /// 退避窗口结束时间：在此之前不再尝试拉起，直接内联解码
  DateTime? _nextStartAt;

  /// 退出日志节流：Isolate 反复退出时不至于刷爆日志
  DateTime? _lastExitLogAt;

  /// 等待投递的帧（保序）
  final Queue<_PendingFrame> _queue = Queue<_PendingFrame>();

  /// 已投递给子 isolate、尚未回包的帧
  final Map<int, _PendingFrame> _inFlight = <int, _PendingFrame>{};

  int _queuedBytes = 0;

  /// 投递循环是否在跑：保证同一时刻只有一个 pump
  bool _pumping = false;

  /// 解码 Isolate 当前是否在跑（仅测试用）
  bool get debugIsWorkerRunning => _sendPort != null;

  /// 当前排队帧数（仅测试用）
  int get debugQueuedFrames => _queue.length;

  /// 当前在途帧数（仅测试用）
  int get debugInFlightFrames => _inFlight.length;

  /// 当前排队字节数（仅测试用）
  int get debugQueuedBytes => _queuedBytes;

  Future<Map<String, dynamic>> decodeBilibili(List<int> data) =>
      _decode('bilibili', data);

  Future<Map<String, dynamic>> decodeDouyin(List<int> data) =>
      _decode('douyin', data);

  Future<Map<String, dynamic>> decodeHuya(List<int> data) =>
      _decode('huya', data);

  Future<Map<String, dynamic>> decodeDouyu(List<int> data) =>
      _decode('douyu', data);

  Future<Map<String, dynamic>> _decode(String platform, List<int> data) {
    if (_disposed) throw StateError('Danmaku decoder is disposed');
    final payload = data is Uint8List ? data : Uint8List.fromList(data);
    final frame = _PendingFrame(++_nextRequestId, platform, payload);
    if (!_enqueue(frame)) {
      // 队列已满且这一帧本身就超预算：直接丢弃，调用方拿到空结果
      return Future<Map<String, dynamic>>.value(_droppedResult());
    }
    return frame.completer.future;
  }

  /// 入队并触发投递。队列满时丢最旧的帧——弹幕是实时数据，
  /// 保新弃旧比保旧弃新更符合观看语义，也能把延迟压住。
  bool _enqueue(_PendingFrame frame) {
    // 单帧就超过整个队列预算：直接丢弃，避免一帧把队列顶爆
    if (frame.size > maxQueuedBytes) {
      LiveMetrics.instance.recordDecoderDrop(1);
      return false;
    }
    while (_queue.isNotEmpty &&
        (_queue.length >= maxQueuedFrames ||
            _queuedBytes + frame.size > maxQueuedBytes)) {
      final dropped = _queue.removeFirst();
      _queuedBytes -= dropped.size;
      dropped.completeWith(_droppedResult());
      LiveMetrics.instance.recordDecoderDrop(1);
    }
    _queue.add(frame);
    _queuedBytes += frame.size;
    _schedulePump();
    return true;
  }

  static Map<String, dynamic> _droppedResult() => <String, dynamic>{
        'messages': const <Object?>[],
        'messageCount': 0,
        'elapsedUs': 0,
        'dropped': true,
      };

  void _schedulePump() {
    if (_pumping || _disposed) return;
    _pumping = true;
    unawaited(_pump());
  }

  /// 唯一的投递循环：从排队区取帧 → 投给子 isolate（或内联兜底）。
  /// 只有这里会推进队列，因此帧顺序天然保持，在途窗口也不会超限。
  Future<void> _pump() async {
    try {
      while (!_disposed &&
          _inFlight.length < maxInFlightFrames &&
          _queue.isNotEmpty) {
        final frame = _queue.first;
        SendPort? sendPort;
        try {
          sendPort = await _acquireSendPort();
        } catch (_) {
          sendPort = null;
        }
        // 等待端口期间可能已被复位/销毁：帧已不在队列就跳过
        if (!_queue.remove(frame)) continue;
        _queuedBytes -= frame.size;

        if (_disposed) {
          frame.completeError(StateError('Danmaku decoder is disposed'));
          continue;
        }

        if (sendPort == null) {
          // 解码 Isolate 不可用：退化为当前 isolate 内联解码。
          // 弹幕是实时数据，宁可短暂占用 UI 线程也不能整条链路停摆。
          frame.completeWith(_decodeInline(frame.platform, frame.payload));
          frame.releasePayload();
          // 让出事件循环，避免退避窗口内一次性把整队内联解码完卡住 UI
          await Future<void>.delayed(Duration.zero);
          continue;
        }

        _inFlight[frame.id] = frame;
        try {
          sendPort.send(<Object?>[
            frame.id,
            frame.platform,
            TransferableTypedData.fromList(<TypedData>[frame.payload]),
          ]);
        } catch (e) {
          // 端口在获取后失效（Isolate 刚被杀）：失败这一帧并退出窗口，
          // 不能让异常从 unawaited 的 pump 里逃逸
          _inFlight.remove(frame.id);
          frame.completeError(StateError('Danmaku decoder send failed: $e'));
          continue;
        }
        // 字节所有权已转移，主 isolate 不再持有这一帧
        frame.releasePayload();
      }
    } finally {
      _pumping = false;
      // 退出循环可能是因为在途窗口满了：回包释放名额后要继续投递
      if (!_disposed &&
          _inFlight.length < maxInFlightFrames &&
          _queue.isNotEmpty) {
        _schedulePump();
      }
    }
  }

  /// 取可用的解码端口；退避窗口内或拉起失败时返回 null（调用方走内联）
  Future<SendPort?> _acquireSendPort() async {
    final current = _sendPort;
    if (current != null) return current;
    final nextStartAt = _nextStartAt;
    if (nextStartAt != null && DateTime.now().isBefore(nextStartAt)) {
      return null;
    }
    try {
      await _ensureStarted();
    } catch (e) {
      _noteWorkerFailure();
      _logExit('Danmaku decoder isolate unavailable: $e');
      return null;
    }
    return _sendPort;
  }

  /// 在当前 isolate 内完成解码，返回与 Isolate 通路一致的结构
  Map<String, dynamic> _decodeInline(String platform, List<int> data) {
    return switch (platform) {
      'bilibili' => decodeBilibiliFrame(data),
      'douyin' => decodeDouyinFrame(data),
      'huya' => decodeHuyaFrame(data),
      'douyu' => decodeDouyuFrame(data),
      _ => <String, dynamic>{
          'messages': const <Object?>[],
          'messageCount': 0,
          'elapsedUs': 0,
          'error': 'Unknown decoder: $platform',
        },
    };
  }

  Future<void> _ensureStarted() {
    if (_sendPort != null) return Future<void>.value();
    final existing = _startTask;
    if (existing != null) return existing;

    final starting = _start();
    _startTask = starting;
    // 失败时复位 _startTask 以便下次重试；这条旁路 future 只为副作用存在，
    // 错误本身仍由调用方 await 到的 starting 抛出，这里显式忽略
    unawaited(starting.catchError((Object _) {
      if (identical(_startTask, starting)) _startTask = null;
    }));
    return starting;
  }

  Future<void> _start() async {
    final gen = ++_workerGen;
    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();
    _receivePort = receivePort;
    _exitPort = exitPort;
    _errorPort = errorPort;
    final ready = Completer<SendPort>();
    _readyCompleter = ready;
    receivePort.listen((dynamic message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is! List || message.length < 2) return;
      final requestId = message[0] as int;
      final frame = _inFlight.remove(requestId);
      if (frame == null || frame.completer.isCompleted) {
        // 复位后到达的迟到回包：只腾出窗口，不写结果
        _schedulePump();
        return;
      }
      // 收到回包说明 Isolate 活着：清空失败计数与退避窗口
      _failureStreak = 0;
      _nextStartAt = null;
      final result = message[1];
      if (result is Map) {
        frame.completeWith(Map<String, dynamic>.from(result));
      } else {
        frame.completeError(
          StateError('Unexpected danmaku decoder response: $result'),
        );
      }
      // 在途名额释放，继续投递排队帧
      _schedulePump();
    });

    // Isolate 正常退出/被杀/未捕获异常终止都会走到这里
    exitPort.listen((dynamic _) {
      _handleWorkerExit(gen, 'Danmaku decoder isolate exited');
    });
    errorPort.listen((dynamic message) {
      if (gen != _workerGen) return;
      final detail =
          message is List && message.isNotEmpty ? message.first : message;
      _logExit('Danmaku decoder isolate error: $detail');
    });

    try {
      final isolate = await Isolate.spawn(
        _danmakuDecoderMain,
        receivePort.sendPort,
        onExit: exitPort.sendPort,
        onError: errorPort.sendPort,
      );
      if (_disposed) {
        isolate.kill(priority: Isolate.immediate);
        throw StateError('Danmaku decoder is disposed');
      }
      // spawn 期间 Isolate 已退出并复位：本次启动作废，交给下一帧重试
      if (gen != _workerGen) {
        isolate.kill(priority: Isolate.immediate);
        throw StateError('Danmaku decoder isolate exited during startup');
      }
      _isolate = isolate;
      _sendPort = await ready.future;
      if (identical(_readyCompleter, ready)) _readyCompleter = null;
      if (_disposed) throw StateError('Danmaku decoder is disposed');
    } catch (_) {
      if (identical(_readyCompleter, ready)) _readyCompleter = null;
      if (identical(_receivePort, receivePort)) {
        receivePort.close();
        _receivePort = null;
      }
      if (identical(_exitPort, exitPort)) {
        exitPort.close();
        _exitPort = null;
      }
      if (identical(_errorPort, errorPort)) {
        errorPort.close();
        _errorPort = null;
      }
      rethrow;
    }
  }

  /// Isolate 退出：失败全部在途请求、安排退避，下一次 decode 在退避
  /// 窗口结束后重新 spawn，窗口内由调用方内联解码兜底
  void _handleWorkerExit(int gen, String reason) {
    // 已被更新的 Isolate 取代，或已 dispose：只做清理，不再报错
    if (gen != _workerGen) return;
    if (_disposed) return;
    _noteWorkerFailure();
    _logExit(reason);
    _resetWorker(StateError(reason));
  }

  /// 记一次失败并按指数退避（0.5s → 1s → 2s → 4s → 8s）安排下次拉起
  void _noteWorkerFailure() {
    _failureStreak = _failureStreak >= 5 ? 5 : _failureStreak + 1;
    final backoffMs = 500 * (1 << (_failureStreak - 1));
    _nextStartAt = DateTime.now().add(Duration(milliseconds: backoffMs));
  }

  /// 复位解码器状态。调用后 _sendPort/_isolate 为空，在途与排队帧全部失败，
  /// 下一次 [_ensureStarted] 会重新拉起 Isolate。
  void _resetWorker(Object error) {
    // 递增代次，使旧 Isolate 的迟到消息/退出回调全部失效
    _workerGen++;
    final ready = _readyCompleter;
    _readyCompleter = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(error);
      // 启动流程可能已提前退出、没人 await 这个 Completer：
      // 挂一个空的错误处理，避免变成未捕获的异步异常
      unawaited(
        ready.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
    _isolate = null;
    _sendPort = null;
    _startTask = null;
    _receivePort?.close();
    _receivePort = null;
    _exitPort?.close();
    _exitPort = null;
    _errorPort?.close();
    _errorPort = null;

    for (final frame in _inFlight.values) {
      frame.completeError(error);
    }
    _inFlight.clear();
    for (final frame in _queue) {
      frame.completeError(error);
    }
    _queue.clear();
    _queuedBytes = 0;
  }

  void _logExit(String message) {
    final now = DateTime.now();
    final last = _lastExitLogAt;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastExitLogAt = now;
    CoreLog.error(message);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _resetWorker(StateError('Danmaku decoder is disposed'));
  }

  /// 仅测试用：强杀解码 Isolate，模拟被系统回收
  void debugKillIsolate() {
    _isolate?.kill(priority: Isolate.immediate);
  }
}

void _danmakuDecoderMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((dynamic message) {
    if (message is! List || message.length < 3) return;
    final requestId = message[0] as int;
    final platform = message[1] as String;
    // 帧字节由调用方以 TransferableTypedData 转移过来：materialize 拿到
    // 的是外部缓冲的所有权，不会再复制一遍；内联兜底路径仍可能是普通 List
    final payload = message[2];
    final data = switch (payload) {
      TransferableTypedData() => payload.materialize().asUint8List(),
      Uint8List() => payload,
      List() => payload.cast<int>(),
      _ => const <int>[],
    };
    try {
      final result = switch (platform) {
        'bilibili' => decodeBilibiliFrame(data),
        'douyin' => decodeDouyinFrame(data),
        'huya' => decodeHuyaFrame(data),
        'douyu' => decodeDouyuFrame(data),
        _ => <String, dynamic>{'error': 'Unknown decoder: $platform'},
      };
      mainSendPort.send(<Object?>[requestId, result]);
    } catch (error, stackTrace) {
      mainSendPort.send(<Object?>[
        requestId,
        <String, dynamic>{'error': '$error', 'stack': '$stackTrace'},
      ]);
    }
  });
}

/// 帧内多条消息以控制字符分隔；正则在模块级只编译一次
final RegExp _bilibiliMessageSeparator = RegExp(
  r'[\x00-\x1f]+',
  unicode: true,
  multiLine: true,
);

/// Decode one Bilibili notification frame into isolate-sendable values.
Map<String, dynamic> decodeBilibiliFrame(List<int> data) {
  final stopwatch = Stopwatch()..start();
  final messages = <Map<String, dynamic>>[];
  var messageCount = 0;
  String? error;
  try {
    final protocolVersion = _readBigEndian(data, 6, 2);
    final operation = _readBigEndian(data, 8, 4);
    // 16 字节协议头之后的包体：零拷贝视图代替 skip().toList()，
    // 高热房间每秒上千帧时省掉每帧一次的列表拷贝
    final bytes =
        data is Uint8List ? data : Uint8List.fromList(data);
    final body = data.length > 16
        ? Uint8List.sublistView(bytes, 16)
        : Uint8List(0);
    if (operation == 3) {
      messages.add(<String, dynamic>{
        'kind': 'online',
        'data': _readBigEndian(body, 0, 4),
      });
    } else if (operation == 5) {
      List<int> decodedBody = body;
      if (protocolVersion == 2) {
        decodedBody = zlib.decode(decodedBody);
      } else if (protocolVersion == 3) {
        decodedBody = brotli.decode(decodedBody);
      }
      final text = utf8.decode(decodedBody, allowMalformed: true);
      final group = text.split(_bilibiliMessageSeparator);
      for (final jsonMessage in group.where(
        (item) => item.length > 2 && item.startsWith('{'),
      )) {
        messageCount++;
        try {
          final parsed = _parseBilibiliMessage(json.decode(jsonMessage));
          if (parsed != null) messages.add(parsed);
        } catch (_) {
          // Match the old parser's per-message error isolation.
        }
      }
    }
  } catch (e) {
    error = '$e';
  } finally {
    stopwatch.stop();
  }
  return <String, dynamic>{
    'messages': messages,
    'messageCount': messageCount,
    'elapsedUs': stopwatch.elapsedMicroseconds,
    'error': ?error,
  };
}

Map<String, dynamic>? _parseBilibiliMessage(dynamic value) {
  if (value is! Map) return null;
  final command = value['cmd'].toString();
  if (command.contains('DANMU_MSG')) {
    final info = value['info'];
    if (info is! List || info.isEmpty) return null;
    final userInfo = info.length > 2 ? info[2] : null;
    if (userInfo is! List || userInfo.length <= 1) return null;
    final colorInfo = info[0];
    final colorValue = colorInfo is List && colorInfo.length > 3
        ? colorInfo[3]
        : null;
    final color = colorValue is num
        ? colorValue.toInt()
        : int.tryParse('$colorValue') ?? 0;
    return <String, dynamic>{
      'kind': 'chat',
      'userName': userInfo[1].toString(),
      'message': info.length > 1 ? info[1].toString() : '',
      'color': color,
    };
  }
  if (command == 'SUPER_CHAT_MESSAGE') {
    final data = value['data'];
    if (data is! Map) return null;
    final userInfo = data['user_info'];
    if (userInfo is! Map) return null;
    return <String, dynamic>{
      'kind': 'superChat',
      'backgroundBottomColor': data['background_bottom_color'].toString(),
      'backgroundColor': data['background_color'].toString(),
      'endTimeMs': _secondsToMilliseconds(data['end_time']),
      'face': '${userInfo['face']}@200w.jpg',
      'message': data['message'].toString(),
      'price': (data['price'] as num?)?.toInt() ?? 0,
      'startTimeMs': _secondsToMilliseconds(data['start_time']),
      'userName': userInfo['uname'].toString(),
    };
  }
  return null;
}

int _secondsToMilliseconds(dynamic value) =>
    ((value as num?)?.toInt() ?? 0) * 1000;

int _readBigEndian(List<int> data, int offset, int length) {
  if (offset < 0 || offset + length > data.length) {
    throw FormatException('Invalid danmaku frame header');
  }
  var value = 0;
  for (var i = offset; i < offset + length; i++) {
    value = (value << 8) | (data[i] & 0xff);
  }
  return value;
}

/// Decode one Douyin Webcast PushFrame into isolate-sendable values.
Map<String, dynamic> decodeDouyinFrame(List<int> data) {
  final stopwatch = Stopwatch()..start();
  final messages = <Map<String, dynamic>>[];
  var messageCount = 0;
  var needAck = false;
  var logId = 0;
  var internalExt = '';
  String? error;
  try {
    final websocketPackage = PushFrame.fromBuffer(data);
    logId = websocketPackage.logId.toInt();
    if (websocketPackage.payload.isNotEmpty) {
      final decompressed = gzip.decode(websocketPackage.payload);
      final payloadPackage = Response.fromBuffer(decompressed);
      needAck = payloadPackage.needAck;
      internalExt = payloadPackage.internalExt;
      messageCount = payloadPackage.messagesList.length;
      for (final message in payloadPackage.messagesList) {
        try {
          if (message.method == 'WebcastChatMessage') {
            final chat = ChatMessage.fromBuffer(message.payload);
            messages.add(<String, dynamic>{
              'kind': 'chat',
              'message': chat.content,
              'userName': chat.user.nickName,
            });
          } else if (message.method == 'WebcastRoomUserSeqMessage') {
            final online = RoomUserSeqMessage.fromBuffer(message.payload);
            messages.add(<String, dynamic>{
              'kind': 'online',
              'data': online.totalUser.toInt(),
            });
          }
        } catch (_) {
          // A malformed message should not discard other messages in the frame.
        }
      }
    }
  } catch (e) {
    error = '$e';
  } finally {
    stopwatch.stop();
  }
  return <String, dynamic>{
    'messages': messages,
    'messageCount': messageCount,
    'elapsedUs': stopwatch.elapsedMicroseconds,
    'needAck': needAck,
    'logId': logId,
    'internalExt': internalExt,
    'error': ?error,
  };
}

/// 已经是 Uint8List 就直接用，避免每次解码都 fromList 拷一份
Uint8List _toBytes(List<int> data) =>
    data is Uint8List ? data : Uint8List.fromList(data);

/// Decode one Huya Tars push frame into isolate-sendable values.
Map<String, dynamic> decodeHuyaFrame(List<int> data) {
  final stopwatch = Stopwatch()..start();
  final messages = <Map<String, dynamic>>[];
  String? error;
  try {
    var stream = TarsInputStream(_toBytes(data));
    var type = stream.read(0, 0, false);
    if (type == 7) {
      stream = TarsInputStream(stream.readBytes(1, false));
      var pushMessage = HYPushMessage();
      pushMessage.readFrom(stream);
      if (pushMessage.uri == 1400) {
        var notice = HYMessage();
        notice.readFrom(TarsInputStream(_toBytes(pushMessage.msg)));
        messages.add(<String, dynamic>{
          'kind': 'chat',
          'userName': notice.userInfo.nickName,
          'message': notice.content,
          'color': notice.bulletFormat.fontColor,
        });
      } else if (pushMessage.uri == 8006) {
        var online = 0;
        online = TarsInputStream(_toBytes(pushMessage.msg))
            .read(online, 0, false);
        messages.add(<String, dynamic>{
          'kind': 'online',
          'data': online,
        });
      }
    }
  } catch (e) {
    error = '$e';
  } finally {
    stopwatch.stop();
  }
  return <String, dynamic>{
    'messages': messages,
    'messageCount': messages.length,
    'elapsedUs': stopwatch.elapsedMicroseconds,
    'error': ?error,
  };
}

/// Decode one Douyu STT frame into isolate-sendable values.
Map<String, dynamic> decodeDouyuFrame(List<int> data) {
  final stopwatch = Stopwatch()..start();
  final messages = <Map<String, dynamic>>[];
  String? error;
  try {
    var text = _deserializeDouyu(_toBytes(data));
    var jsonData = _sttToJObject(text);
    if (jsonData is Map) {
      // 屏蔽阴间弹幕：dms 为空的是系统/机器人消息
      if (jsonData["type"]?.toString() == "chatmsg" &&
          jsonData["dms"] != null) {
        messages.add(<String, dynamic>{
          'kind': 'chat',
          'userName': jsonData["nn"].toString(),
          'message': jsonData["txt"].toString(),
          'colorType': int.tryParse("${jsonData["col"]}") ?? 0,
        });
      }
    }
  } catch (e) {
    error = '$e';
  } finally {
    stopwatch.stop();
  }
  return <String, dynamic>{
    'messages': messages,
    'messageCount': messages.length,
    'elapsedUs': stopwatch.elapsedMicroseconds,
    'error': ?error,
  };
}

String _deserializeDouyu(Uint8List buffer) {
  var reader = BinaryReader(buffer);
  var fullMsgLength = reader.readInt32(endian: Endian.little);
  reader.readInt32(endian: Endian.little); //fullMsgLength2
  var bodyLength = fullMsgLength - 9;
  reader.readShort(endian: Endian.little); //packType
  reader.readByte(endian: Endian.little); //encrypted
  reader.readByte(endian: Endian.little); //reserved
  var bytes = reader.readBytes(bodyLength);
  reader.readByte(endian: Endian.little); //固定为0
  return utf8.decode(bytes);
}

//辣鸡STT
dynamic _sttToJObject(String str) {
  if (str.contains("//")) {
    var result = [];
    for (var field in str.split("//")) {
      if (field.isEmpty) {
        continue;
      }
      result.add(_sttToJObject(field));
    }
    return result;
  }
  if (str.contains("@=")) {
    var result = {};
    for (var field in str.split('/')) {
      if (field.isEmpty) {
        continue;
      }
      var tokens = field.split("@=");
      var k = tokens[0];
      var v = _unscapeSlashAt(tokens[1]);
      result[k] = _sttToJObject(v);
    }
    return result;
  } else if (str.contains("@A=")) {
    return _sttToJObject(_unscapeSlashAt(str));
  } else {
    return _unscapeSlashAt(str);
  }
}

String _unscapeSlashAt(String str) {
  return str.replaceAll("@S", "/").replaceAll("@A", "@");
}
