import 'core_log.dart';

/// 播放链路轻量观测：弹幕解码耗时与断流恢复的聚合统计。
///
/// 只保存计数与总量，不逐事件留存，自身不构成内存或日志负载。
/// 弹幕解码每累计 2000 条输出一次聚合日志。
/// 数据用于支撑"是否上 Isolate、参数往哪个方向调"的实测判断。
class LiveMetrics {
  LiveMetrics._();
  static final LiveMetrics instance = LiveMetrics._();

  // ---- 弹幕解码 ----
  int _decodeFrames = 0;
  int _decodedMessages = 0;
  int _decodeTotalUs = 0;
  int _decodeWallTotalUs = 0;
  int _decodeMaxUs = 0;
  int _nextDecodeLogAt = 2000;

  /// 因显示预算被丢弃、未进入绘制队列的弹幕条数
  int danmakuDropped = 0;

  /// 因解码队列积压被丢弃的原始帧数（保新弃旧的代价）
  int decoderDroppedFrames = 0;

  /// 记录一帧被解码队列丢弃：这是有界流水线的正常降级，
  /// 不是错误，但要能被观测到
  void recordDecoderDrop(int frames) => decoderDroppedFrames += frames;

  /// 记录一帧弹幕解码的耗时（一帧可能解码出多条消息）
  void recordDanmakuDecode(
    Duration elapsed, {
    int messageCount = 0,
    Duration? wallElapsed,
  }) {
    _decodeFrames++;
    _decodedMessages += messageCount;
    _decodeTotalUs += elapsed.inMicroseconds;
    _decodeWallTotalUs += (wallElapsed ?? elapsed).inMicroseconds;
    if (elapsed.inMicroseconds > _decodeMaxUs) {
      _decodeMaxUs = elapsed.inMicroseconds;
    }
    if (_decodedMessages >= _nextDecodeLogAt) {
      _nextDecodeLogAt = _decodedMessages + 2000;
      CoreLog.i(danmakuSummary());
    }
  }

  void recordDanmakuDrop(int count) => danmakuDropped += count;

  int get decodeFrameCount => _decodeFrames;
  int get decodedMessageCount => _decodedMessages;
  int get averageDecodeUs =>
      _decodeFrames == 0 ? 0 : _decodeTotalUs ~/ _decodeFrames;
  int get averageDecodeWallUs =>
      _decodeFrames == 0 ? 0 : _decodeWallTotalUs ~/ _decodeFrames;

  /// Start a fresh playback session's counters when entering/switching rooms.
  void reset() {
    _decodeFrames = 0;
    _decodedMessages = 0;
    _decodeTotalUs = 0;
    _decodeWallTotalUs = 0;
    _decodeMaxUs = 0;
    _nextDecodeLogAt = 2000;
    danmakuDropped = 0;
    decoderDroppedFrames = 0;
    recoveryEpisodes = 0;
    recoverySucceeded = 0;
    recoveryExhausted = 0;
    recoveryAttemptsTotal = 0;
  }

  String danmakuSummary() {
    if (_decodeFrames == 0) {
      return '弹幕解码：暂无数据';
    }
    return '弹幕解码: $_decodedMessages条/$_decodeFrames帧, '
        'avg=${averageDecodeUs}us/帧 (wall ${averageDecodeWallUs}us), '
        'max=${_decodeMaxUs}us/帧, 预算丢弃=$danmakuDropped条, '
        '解码丢弃=$decoderDroppedFrames帧';
  }

  // ---- 断流恢复 ----
  int recoveryEpisodes = 0;
  int recoverySucceeded = 0;
  int recoveryExhausted = 0;
  int recoveryAttemptsTotal = 0;

  /// 记录一次恢复动作（重开当前流/换线路/刷新流信息）
  void recordRecoveryAttempt() => recoveryAttemptsTotal++;

  /// 一轮恢复终结时记录结果：重新起播=成功，进入终态（
  /// 播放失败/状态未知/未开播）=耗尽
  void recordRecoveryEnd({required bool succeeded}) {
    recoveryEpisodes++;
    if (succeeded) {
      recoverySucceeded++;
    } else {
      recoveryExhausted++;
    }
  }

  String recoverySummary() =>
      '断流恢复: $recoveryEpisodes轮, 起播成功$recoverySucceeded, '
      '进入终态$recoveryExhausted, 累计动作$recoveryAttemptsTotal次';
}
