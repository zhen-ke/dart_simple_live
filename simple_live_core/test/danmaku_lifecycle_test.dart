import 'dart:async';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  group('stop while danmaku args are resolving', () {
    test('Bilibili does not connect after stop', () async {
      final args = Completer<Object?>();
      final danmaku = BiliBiliDanmaku();
      final starting = danmaku.start(args.future);

      await danmaku.stop();
      args.complete(
        BiliBiliDanmakuArgs(
          roomId: 1,
          token: '',
          serverHost: 'localhost',
          buvid: '',
          uid: 0,
          cookie: '',
        ),
      );
      await starting;

      expect(danmaku.webScoketUtils, isNull);
    });

    test('Douyin does not connect after stop', () async {
      final args = Completer<Object?>();
      final danmaku = DouyinDanmaku();
      final starting = danmaku.start(args.future);

      await danmaku.stop();
      args.complete(
        DouyinDanmakuArgs(
          webRid: '1',
          roomId: '1',
          userId: '1',
          cookie: '',
        ),
      );
      await starting;

      expect(danmaku.webScoketUtils, isNull);
    });

    test('Douyu does not connect after stop', () async {
      final args = Completer<Object?>();
      final danmaku = DouyuDanmaku();
      final starting = danmaku.start(args.future);

      await danmaku.stop();
      args.complete('1');
      await starting;

      expect(danmaku.webScoketUtils, isNull);
    });

    test('Huya does not connect after stop', () async {
      final args = Completer<Object?>();
      final danmaku = HuyaDanmaku();
      final starting = danmaku.start(args.future);

      await danmaku.stop();
      args.complete(HuyaDanmakuArgs(ayyuid: 1, topSid: 1, subSid: 1));
      await starting;

      expect(danmaku.webScoketUtils, isNull);
    });
  });
}
