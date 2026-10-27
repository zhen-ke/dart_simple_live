import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class Log {
  static LogFileWriter? logFileWriter;

  /// Package information: set by the host right after bootstrap; only used when writing the log file header
  static PackageInfo? packageInfo;

  static DateFormat timeFormat = DateFormat("HH:mm:ss");

  /// 是否输出日志：debug 默认开启；profile 用于性能测量，必须默认静默；
  /// release 仅在用户开启"日志记录"后打开。
  /// 文件写入仍由 [logFileWriter] 是否存在控制。
  static bool enabled = kDebugMode;

  static void initWriter() {
    logFileWriter ??= LogFileWriter();
    enabled = true;
  }


  static void disposeWriter() {
    unawaited(logFileWriter?.close());
    logFileWriter = null;
    enabled = kDebugMode;
  }

  static void writeLog(Object content, [Level level = Level.info]) {
    if (!enabled) return;
    logFileWriter?.write(
      "[${level.name.toUpperCase()}] $_currentTime：$content",
    );
  }

  /// 崩溃文件上限：只保留最近一段，超出即重写，避免无界增长
  static const int _maxCrashFileBytes = 64 * 1024;

  /// 致命错误：不受普通日志开关影响，至少输出到控制台；
  /// 用户开启日志文件时同时落盘。此外无论开关状态，
  /// 都追加到固定崩溃文件（见 [_persistCrash]），release 下的
  /// 偶发崩溃才能被导出定位，而不是只存在于控制台里
  static void crash(Object error, StackTrace stackTrace) {
    final message =
        "[FATAL] ${DateTime.now().toIso8601String()} $error\n$stackTrace";
    debugPrint(message);
    logFileWriter?.write(message);
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

  static RxList<DebugLogModel> debugLogs = <DebugLogModel>[].obs;

  /// 调试日志内存上限：超出丢弃最旧记录，
  /// 防止长时间运行时（尤其 Profile 构建）无界增长干扰性能判断
  static const int _maxDebugLogs = 500;

  static void addDebugLog(String content, Color? color) {
    if (kReleaseMode) {
      return;
    }
    if (content.contains("请求响应")) {
      content = content.split("\n").join('\n💡 ');
    }
    try {
      debugLogs.insert(0, DebugLogModel(DateTime.now(), content, color: color));
      if (debugLogs.length > _maxDebugLogs) {
        debugLogs.removeRange(_maxDebugLogs, debugLogs.length);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(e.toString());
      }
    }
  }

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

  static void d(String message, [bool writeFile = true]) {
    if (!enabled) return;
    addDebugLog(message, Colors.orange);
    logger.d("${DateTime.now().toString()}\n$message");
    if (writeFile) {
      writeLog(message, Level.debug);
    }
  }

  static void i(String message, [bool writeFile = true]) {
    if (!enabled) return;
    addDebugLog(message, Colors.blue);
    logger.i("${DateTime.now().toString()}\n$message");
    if (writeFile) {
      writeLog(message, Level.info);
    }
  }

  static void e(String message, StackTrace stackTrace,
      [bool writeFile = true]) {
    if (!enabled) return;
    addDebugLog('$message\r\n\r\n$stackTrace', Colors.red);
    logger.e("${DateTime.now().toString()}\n$message", stackTrace: stackTrace);
    if (writeFile) {
      writeLog("$message\n$stackTrace", Level.error);
    }
  }

  static void w(String message, [bool writeFile = true]) {
    if (!enabled) return;
    addDebugLog(message, Colors.pink);
    logger.w("${DateTime.now().toString()}\n$message");
    if (writeFile) {
      writeLog(message, Level.warning);
    }
  }

  static void logPrint(dynamic obj, [bool writeFile = true]) {
    if (!enabled) return;
    addDebugLog(obj.toString(), Colors.red);
    if (writeFile) {
      writeLog(obj, Level.info);
    }
    //logger.e(obj.toString(), obj, obj?.stackTrace);
    if (kDebugMode) {
      debugPrint(obj.toString());
    }
  }

  static String get _currentTime => timeFormat.format(DateTime.now());
}

class LogFileWriter {
  late String fileName;
  LogFileWriter() {
    var dt = DateFormat("yyyy-MM-dd HH-mm-ss").format(DateTime.now());
    fileName = "$dt.log";
    initFile();
  }

  /// 单个日志文件大小上限：超出切到新文件，避免无界追加
  static const int _maxFileBytes = 8 * 1024 * 1024;

  /// 日志文件数量上限与保留期：超限的旧文件在启动时清理
  static const int _maxLogFiles = 10;
  static const Duration _logRetention = Duration(days: 7);

  File? _logFile;
  IOSink? fileWriter;
  int _writtenBytes = 0;
  int _fileSeq = 0;

  void initFile() async {
    var supportDir = await getApplicationSupportDirectory();
    var logDir = Directory("${supportDir.path}/log");
    if (!await logDir.exists()) {
      await logDir.create();
    }
    await _pruneOldLogs(logDir);
    _logFile = File("${logDir.path}/$fileName");
    fileWriter = _logFile!.openWrite(mode: FileMode.append);
    writeSystemInfo();
  }

  /// 清理超过保留期的日志；存活文件仍超上限时淘汰最旧的
  Future<void> _pruneOldLogs(Directory logDir) async {
    try {
      var files = await logDir
          .list()
          .where((e) => e is File && e.path.endsWith(".log"))
          .cast<File>()
          .toList();
      var now = DateTime.now();
      var alive = <(File, DateTime)>[];
      for (var f in files) {
        var stat = await f.stat();
        if (now.difference(stat.modified) > _logRetention) {
          await f.delete();
        } else {
          alive.add((f, stat.modified));
        }
      }
      alive.sort((a, b) => a.$2.compareTo(b.$2));
      // 为本次新文件留出位置
      while (alive.length >= _maxLogFiles) {
        await alive.removeAt(0).$1.delete();
      }
    } catch (_) {}
  }

  void write(String content) {
    fileWriter?.write(content);
    fileWriter?.write("\r\n");
    // 粗略计字节（长度不等于 UTF-8 字节数，仅用于轮转阈值）
    _writtenBytes += content.length + 2;
    if (_writtenBytes > _maxFileBytes) {
      _rotateFile();
    }
  }

  /// 单文件过大时切到新文件
  void _rotateFile() async {
    var old = fileWriter;
    fileWriter = null;
    _writtenBytes = 0;
    try {
      await old?.close();
      final file = _logFile;
      if (file == null) return;
      _fileSeq++;
      var base = fileName.endsWith(".log")
          ? fileName.substring(0, fileName.length - 4)
          : fileName;
      _logFile = File("${file.parent.path}/${base}_$_fileSeq.log");
      fileWriter = _logFile!.openWrite();
    } catch (_) {}
  }

  Future close() async {
    await fileWriter?.close();
  }

  void writeSystemInfo() async {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    write("System Info:");
    write("Current Time: ${DateTime.now()}");
    write("Platform: ${Platform.operatingSystem}");
    write("Version: ${Platform.operatingSystemVersion}");
    write("Local: ${Platform.localeName}");
    write(
      "App Version: ${Log.packageInfo?.version}+${Log.packageInfo?.buildNumber ?? ''}",
    );
    if (Platform.isAndroid) {
      write((await deviceInfo.androidInfo).data.toString());
    } else if (Platform.isIOS) {
      write((await deviceInfo.iosInfo).data.toString());
    } else if (Platform.isLinux) {
      write((await deviceInfo.linuxInfo).data.toString());
    } else if (Platform.isMacOS) {
      write((await deviceInfo.macOsInfo).data.toString());
    } else if (Platform.isWindows) {
      write((await deviceInfo.windowsInfo).data.toString());
    }
    write("End System Info");
  }
}

class DebugLogModel {
  final String content;
  final DateTime datetime;
  final Color? color;
  DebugLogModel(this.datetime, this.content, {this.color});
}
