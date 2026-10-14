import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:brotli/brotli.dart';
import 'package:simple_live_core/src/danmaku/proto/douyin.pb.dart';

/// Long-lived decoder isolate for the hot Bilibili/Douyin frame paths.
/// Keeping one worker per room avoids paying Isolate.run's spawn cost for
/// every frame while preserving frame order.
class DanmakuDecodeWorker {
  ReceivePort? _receivePort;
  Isolate? _isolate;
  SendPort? _sendPort;
  Future<void>? _startTask;
  Completer<SendPort>? _readyCompleter;
  int _nextRequestId = 0;
  bool _disposed = false;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  Future<Map<String, dynamic>> decodeBilibili(List<int> data) =>
      _decode('bilibili', data);

  Future<Map<String, dynamic>> decodeDouyin(List<int> data) =>
      _decode('douyin', data);

  Future<Map<String, dynamic>> _decode(String platform, List<int> data) async {
    if (_disposed) throw StateError('Danmaku decoder is disposed');
    await _ensureStarted();
    if (_disposed) throw StateError('Danmaku decoder is disposed');

    final requestId = ++_nextRequestId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    _sendPort!.send(<Object?>[requestId, platform, data]);
    return completer.future;
  }

  Future<void> _ensureStarted() {
    if (_sendPort != null) return Future<void>.value();
    final existing = _startTask;
    if (existing != null) return existing;

    final starting = _start();
    _startTask = starting;
    starting.catchError((Object _) {
      if (identical(_startTask, starting)) _startTask = null;
    });
    return starting;
  }

  Future<void> _start() async {
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    final ready = Completer<SendPort>();
    _readyCompleter = ready;
    receivePort.listen((dynamic message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is! List || message.length < 2) return;
      final requestId = message[0] as int;
      final completer = _pending.remove(requestId);
      if (completer == null || completer.isCompleted) return;
      final result = message[1];
      if (result is Map) {
        completer.complete(Map<String, dynamic>.from(result));
      } else {
        completer.completeError(
          StateError('Unexpected danmaku decoder response: $result'),
        );
      }
    });

    try {
      final isolate = await Isolate.spawn(
        _danmakuDecoderMain,
        receivePort.sendPort,
      );
      if (_disposed) {
        isolate.kill(priority: Isolate.immediate);
        throw StateError('Danmaku decoder is disposed');
      }
      _isolate = isolate;
      _sendPort = await ready.future;
      _readyCompleter = null;
      if (_disposed) throw StateError('Danmaku decoder is disposed');
    } catch (_) {
      _readyCompleter = null;
      receivePort.close();
      if (identical(_receivePort, receivePort)) _receivePort = null;
      rethrow;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final ready = _readyCompleter;
    _readyCompleter = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('Danmaku decoder is disposed'));
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    _receivePort?.close();
    _receivePort = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Danmaku decoder is disposed'));
      }
    }
    _pending.clear();
  }
}

void _danmakuDecoderMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((dynamic message) {
    if (message is! List || message.length < 3) return;
    final requestId = message[0] as int;
    final platform = message[1] as String;
    final data = (message[2] as List).cast<int>();
    try {
      final result = switch (platform) {
        'bilibili' => decodeBilibiliFrame(data),
        'douyin' => decodeDouyinFrame(data),
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

/// Decode one Bilibili notification frame into isolate-sendable values.
Map<String, dynamic> decodeBilibiliFrame(List<int> data) {
  final stopwatch = Stopwatch()..start();
  final messages = <Map<String, dynamic>>[];
  var messageCount = 0;
  String? error;
  try {
    final protocolVersion = _readBigEndian(data, 6, 2);
    final operation = _readBigEndian(data, 8, 4);
    final body = data.skip(16).toList(growable: false);
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
      final group = text.split(
        RegExp(r'[\x00-\x1f]+', unicode: true, multiLine: true),
      );
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
    if (error != null) 'error': error,
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
    if (error != null) 'error': error,
  };
}
