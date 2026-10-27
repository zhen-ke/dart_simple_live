import 'dart:convert';
import 'dart:isolate';

/// 大列表 JSON 编码放后台 isolate：历史记录等大列表在 UI 线程
/// 序列化会造成可感知的掉帧（局域网/房间同步均走这里）
Future<String> encodeJsonInIsolate(Object? value) =>
    Isolate.run(() => jsonEncode(value));

/// 大列表 JSON 解码放后台 isolate，与 [encodeJsonInIsolate] 对称
Future<dynamic> decodeJsonInIsolate(String source) =>
    Isolate.run(() => jsonDecode(source));
