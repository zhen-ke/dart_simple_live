import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:simple_live_core/src/common/danmaku_decode_worker.dart';
import 'package:simple_live_core/src/common/live_metrics.dart';
import 'package:simple_live_core/src/danmaku/proto/douyin.pb.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';
import 'package:test/test.dart';

/// 斗鱼帧：4+4 长度、2 包类型、1 加密、1 保留、正文、1 结尾
Uint8List buildDouyuFrame(String body) {
  final bodyBytes = Uint8List.fromList(body.codeUnits);
  final frame = Uint8List(12 + bodyBytes.length + 1);
  final data = ByteData.view(frame.buffer);
  data.setInt32(0, 9 + bodyBytes.length, Endian.little);
  data.setInt32(4, 9 + bodyBytes.length, Endian.little);
  data.setInt16(8, 689, Endian.little);
  frame[10] = 0;
  frame[11] = 0;
  frame.setRange(12, 12 + bodyBytes.length, bodyBytes);
  frame[12 + bodyBytes.length] = 0;
  return frame;
}

/// 虎牙帧：外层 tag0=int 7，tag1=bytes(HYPushMessage)
Uint8List buildHuyaFrame(int uri, Uint8List message) {
  final push = TarsOutputStream()
    ..write(0, 0)
    ..write(uri, 1)
    ..write(message, 2)
    ..write(0, 3);
  final outer = TarsOutputStream()
    ..write(7, 0)
    ..write(push.toUint8List(), 1);
  return outer.toUint8List();
}

/// HYMessage：tag0 发送者结构（内含 tag2 昵称）、tag3 正文
Uint8List buildHuyaChatMessage(String nickName, String content) {
  final message = TarsOutputStream()
    ..writeHead(TarsStructType.STRUCT_BEGIN.index, 0)
    ..writeString(nickName, 2)
    ..writeHead(TarsStructType.STRUCT_END.index, 0)
    ..writeString(content, 3);
  return message.toUint8List();
}

void main() {
  group('DanmakuDecodeWorker', () {
    late DanmakuDecodeWorker worker;

    setUp(() {
      worker = DanmakuDecodeWorker();
    });

    tearDown(() {
      worker.dispose();
    });

    test('caps the queue and drops oldest frames instead of growing', () async {
      LiveMetrics.instance.reset();
      final futures = <Future<Map<String, dynamic>>>[];
      // 同步连发：投递循环还没来得及启动，队列会先被顶满。
      // 修复前这里每一帧都会挂起等待，内存随帧数线性增长。
      for (var i = 0; i < 200; i++) {
        futures.add(
          worker.decodeDouyu(
            buildDouyuFrame('type@=chatmsg/nn@=u$i/txt@=m$i/dms@=1/'),
          ),
        );
      }

      expect(worker.debugQueuedFrames, lessThanOrEqualTo(
        DanmakuDecodeWorker.maxQueuedFrames,
      ));
      expect(worker.debugQueuedBytes, lessThanOrEqualTo(
        DanmakuDecodeWorker.maxQueuedBytes,
      ));

      final results = await Future.wait(futures)
          .timeout(const Duration(seconds: 10));

      // 被丢弃的帧以空结果返回，不会悬挂
      expect(results.where((r) => r['dropped'] == true), isNotEmpty);
      expect(
        LiveMetrics.instance.decoderDroppedFrames,
        greaterThan(0),
      );

      // 未被丢弃的帧仍然按顺序解出
      final delivered = results
          .where((r) => r['dropped'] != true)
          .expand((r) => (r['messages'] as List).cast<Map>())
          .map((m) => m['message'] as String)
          .toList();
      final expectedOrder = List<String>.generate(200, (i) => 'm$i');
      final deliveredIndexes = delivered
          .map((text) => expectedOrder.indexOf(text))
          .toList();
      expect(deliveredIndexes, orderedEquals(List.of(deliveredIndexes)..sort()));
      expect(worker.debugInFlightFrames, lessThanOrEqualTo(
        DanmakuDecodeWorker.maxInFlightFrames,
      ));
    });

    test('decodes a Bilibili frame away from the caller', () async {
      const payload =
          '{"cmd":"DANMU_MSG","info":[[0,0,0,16711680],"hello",[0,"alice"]]}';
      final body = utf8.encode(payload);
      final header = ByteData(16)
        ..setUint32(0, 16 + body.length)
        ..setUint16(4, 16)
        ..setUint16(6, 0)
        ..setUint32(8, 5)
        ..setUint32(12, 1);
      final frame = <int>[...header.buffer.asUint8List(), ...body];

      final decoded = await worker.decodeBilibili(frame);
      final messages = decoded['messages'] as List;

      expect(decoded['messageCount'], 1);
      expect(messages, hasLength(1));
      expect(messages.single['kind'], 'chat');
      expect(messages.single['userName'], 'alice');
      expect(messages.single['message'], 'hello');
      expect(messages.single['color'], 16711680);
    });

    test('decodes Douyin gzip payload and ACK data in the isolate', () async {
      final response = Response()
        ..needAck = true
        ..internalExt = 'ack-token';
      final frame = PushFrame()
        ..logId = Int64(1234)
        ..payload = gzip.encode(response.writeToBuffer());

      final decoded = await worker.decodeDouyin(frame.writeToBuffer());

      expect(decoded['messageCount'], 0);
      expect(decoded['needAck'], isTrue);
      expect(decoded['logId'], 1234);
      expect(decoded['internalExt'], 'ack-token');
    });

    test('ignores an empty Douyin heartbeat frame', () async {
      final decoded = await worker.decodeDouyin(const <int>[]);

      expect(decoded['messages'], isEmpty);
      expect(decoded['messageCount'], 0);
      expect(decoded['needAck'], isFalse);
    });

    test('decodes a Douyu chat frame in the isolate', () async {
      final decoded = await worker.decodeDouyu(
        buildDouyuFrame('type@=chatmsg/nn@=alice/txt@=hello/col@=1/dms@=1/'),
      );
      final messages = decoded['messages'] as List;

      expect(decoded['error'], isNull);
      expect(messages, hasLength(1));
      expect(messages.single['kind'], 'chat');
      expect(messages.single['userName'], 'alice');
      expect(messages.single['message'], 'hello');
      expect(messages.single['colorType'], 1);
    });

    test('drops a Douyu frame without dms', () async {
      final decoded = await worker.decodeDouyu(
        buildDouyuFrame('type@=chatmsg/nn@=bot/txt@=hi/col@=0/'),
      );

      expect(decoded['error'], isNull);
      expect(decoded['messages'], isEmpty);
    });

    test('decodes a Huya chat frame in the isolate', () async {
      final decoded = await worker.decodeHuya(
        buildHuyaFrame(1400, buildHuyaChatMessage('bob', 'hello huya')),
      );
      final messages = decoded['messages'] as List;

      expect(decoded['error'], isNull);
      expect(messages, hasLength(1));
      expect(messages.single['kind'], 'chat');
      expect(messages.single['userName'], 'bob');
      expect(messages.single['message'], 'hello huya');
    });

    test('decodes inline instead of hanging while the isolate is down',
        () async {
      await worker.decodeDouyu(
        buildDouyuFrame('type@=chatmsg/nn@=alice/txt@=hi/dms@=1/'),
      );

      worker.debugKillIsolate();
      // 等退出事件落地：修复前从这里开始的所有请求都会永久悬挂
      await _waitUntil(() => !worker.debugIsWorkerRunning);
      expect(worker.debugIsWorkerRunning, isFalse);

      final decoded = await worker
          .decodeDouyu(
            buildDouyuFrame('type@=chatmsg/nn@=alice/txt@=still-alive/dms@=1/'),
          )
          .timeout(const Duration(seconds: 3));
      final messages = decoded['messages'] as List;

      expect(decoded['error'], isNull);
      expect(messages, hasLength(1));
      expect(messages.single['message'], 'still-alive');
      // 仍在退避窗口内：这一帧是内联解码，没有重新拉起 Isolate
      expect(worker.debugIsWorkerRunning, isFalse);
    });

    test('respawns the isolate after the crash backoff', () async {
      await worker.decodeDouyu(
        buildDouyuFrame('type@=chatmsg/nn@=alice/txt@=before/dms@=1/'),
      );
      expect(worker.debugIsWorkerRunning, isTrue);

      worker.debugKillIsolate();
      await _waitUntil(() => !worker.debugIsWorkerRunning);
      // 越过 500ms 退避窗口
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final decoded = await worker.decodeDouyu(
        buildDouyuFrame('type@=chatmsg/nn@=bob/txt@=after/dms@=1/'),
      );
      final messages = decoded['messages'] as List;

      expect(decoded['error'], isNull);
      expect(messages, hasLength(1));
      expect(messages.single['userName'], 'bob');
      expect(messages.single['message'], 'after');
      expect(worker.debugIsWorkerRunning, isTrue);
    });
  });
}

/// 轮询等待条件成立（最多 2 秒），避免依赖固定 sleep 的时序
Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
