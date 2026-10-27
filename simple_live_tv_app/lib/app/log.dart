import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:logger/logger.dart';

class Log {
  static RxList<DebugLogModel> debugLogs = <DebugLogModel>[].obs;

  /// TV 端没有日志文件/查看页，release 下默认不输出日志。
  static bool enabled = !kReleaseMode;

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

  /// 致命错误：release 下也要留下可定位的信息。
  static void crash(Object error, StackTrace stackTrace) {
    debugPrint(
      "[FATAL] ${DateTime.now().toIso8601String()} $error\n$stackTrace",
    );
  }
}

class DebugLogModel {
  final String content;
  final DateTime datetime;
  final Color? color;
  DebugLogModel(this.datetime, this.content, {this.color});
}
