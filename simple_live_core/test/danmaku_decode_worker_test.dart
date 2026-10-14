import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:simple_live_core/src/common/danmaku_decode_worker.dart';
import 'package:simple_live_core/src/danmaku/proto/douyin.pb.dart';
import 'package:test/test.dart';

void main() {
  group('DanmakuDecodeWorker', () {
    late DanmakuDecodeWorker worker;

    setUp(() {
      worker = DanmakuDecodeWorker();
    });

    tearDown(() {
      worker.dispose();
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
  });
}
