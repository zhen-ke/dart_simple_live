import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

class Log {
  static RxList<DebugLogModel> debugLogs = <DebugLogModel>[].obs;

  /// TV 端没有日志文件/查看页。debug 默认开启；profile 用于性能测量，
  /// 必须默认静默；release 下保持关闭
  static bool enabled = kDebugMode;

  static Logger logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.none,
    ),
  );

  static void d(String message) {
    if (!enabled) return;
    logger.d("${DateTime.now().toString()}\n$message");
  }

  static void i(String message) {
    if (!enabled) return;
    logger.i("${DateTime.now().toString()}\n$message");
  }

  static void e(String message, StackTrace stackTrace) {
    if (!enabled) return;
    logger.e("${DateTime.now().toString()}\n$message", stackTrace: stackTrace);
  }

  static void w(String message) {
    if (!enabled) return;
    logger.w("${DateTime.now().toString()}\n$message");
  }

  static void logPrint(dynamic obj) {
    if (!enabled) return;
    //logger.e(obj.toString(), obj, obj?.stackTrace);
    if (kDebugMode) {
      debugPrint(obj.toString());
    }
  }

  /// 崩溃文件上限：只保留最近一段，超出即重写，避免无界增长
  static const int _maxCrashFileBytes = 64 * 1024;

  /// 致命错误：release 下也要留下可定位的信息。TV 没有日志页，
  /// 但崩溃会追加到固定文件，复现问题时可直接取走定位
  static void crash(Object error, StackTrace stackTrace) {
    final message =
        "[FATAL] ${DateTime.now().toIso8601String()} $error\n$stackTrace";
    debugPrint(message);
    unawaited(_persistCrash(message));
  }

  /// 崩溃记录走惰性 IO：只在真的发生崩溃时才触碰磁盘。
  /// 写失败必须静默——崩溃处理器里再抛异常就是二次事故
  static Future<void> _persistCrash(String message) async {
    try {
      var supportDir = await getApplicationSupportDirectory();
      var file = File("${supportDir.path}/crash/crash.log");
      if (await file.exists() && await file.length() > _maxCrashFileBytes) {
        await file.writeAsString("$message\r\n");
        return;
      }
      await file.parent.create(recursive: true);
      await file.writeAsString("$message\r\n", mode: FileMode.append);
    } catch (_) {}
  }
}

class DebugLogModel {
  final String content;
  final DateTime datetime;
  final Color? color;
  DebugLogModel(this.datetime, this.content, {this.color});
}
