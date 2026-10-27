import 'dart:async';

import 'package:dart_quickjs/dart_quickjs.dart';

import 'core_log.dart';

/// 常驻 QuickJS 运行时宿主。
///
/// 签名脚本（抖音 ABogus/MSSDK、斗鱼 CryptoJS）体积大、编译成本高，
/// 每次调用都新建 [JsRuntime] 并重新 eval 会把签名变成 UI 线程上的
/// 主要卡顿源。这里统一做三件事：
/// - 首次使用时才创建运行时，bootstrap 脚本只 eval 一次；
/// - 空闲 [idleTimeout] 后释放运行时，避免长期占用数 MB 内存；
/// - 脚本执行失败时丢弃运行时，下一次调用从干净的上下文重建，
///   不把半执行状态留给后续签名。
///
/// QuickJS 运行时是 isolate 亲和的：本类只能在创建它的 isolate 内使用。
/// 当前签名调用都在主 isolate，符合该约束。
class QuickJsRuntimeHost {
  QuickJsRuntimeHost({
    required this.name,
    required this.bootstrap,
    this.memoryLimit = 4 * 1024 * 1024,
    this.maxStackSize = 64 * 1024,
    this.idleTimeout = const Duration(minutes: 5),
  });

  /// 运行时名称，仅用于错误信息与诊断。
  final String name;

  /// 只执行一次的初始化脚本。
  final String bootstrap;

  final int memoryLimit;
  final int maxStackSize;

  /// 连续多久没有调用就释放运行时。
  final Duration idleTimeout;

  JsRuntime? _runtime;
  Timer? _idleTimer;
  bool _disposed = false;
  int _bootstrapCount = 0;

  /// bootstrap 脚本被执行的次数；正常应始终为 1。
  int get bootstrapCount => _bootstrapCount;

  /// 当前是否持有运行时（仅诊断/测试用）。
  bool get isAlive => _runtime != null;

  /// 在常驻运行时上执行一段脚本。
  ///
  /// [action] 必须是同步的：QuickJS eval 本身是同步调用，异步化只会
  /// 把同一个运行时暴露给并发调用，反而需要额外加锁。
  T run<T>(T Function(JsRuntime runtime) action) {
    final runtime = _acquire();
    try {
      return action(runtime);
    } catch (error, stackTrace) {
      // 脚本可能只执行了一半，继续复用会让后续签名建立在脏上下文上。
      _releaseRuntime();
      CoreLog.error(error);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  JsRuntime _acquire() {
    if (_disposed) {
      throw StateError('QuickJS runtime host "$name" has been disposed');
    }

    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, _releaseRuntime);

    final existing = _runtime;
    if (existing != null) return existing;

    final runtime = JsRuntime(
      memoryLimit: memoryLimit,
      maxStackSize: maxStackSize,
    );
    try {
      runtime.eval(bootstrap);
    } catch (_) {
      _idleTimer?.cancel();
      _idleTimer = null;
      runtime.dispose();
      rethrow;
    }
    _bootstrapCount++;
    _runtime = runtime;
    return runtime;
  }

  void _releaseRuntime() {
    _idleTimer?.cancel();
    _idleTimer = null;
    final runtime = _runtime;
    _runtime = null;
    runtime?.dispose();
  }

  /// 主动释放运行时；释放后宿主不可再使用。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _releaseRuntime();
  }
}
