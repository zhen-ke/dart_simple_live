import 'dart:async';

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
  }
  final FocusNode focusNode = FocusNode();
  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  /// 开播状态三态：查询失败是 unknown，不能与 offline 混为一谈
  var liveStatus = LiveStatus.unknown.obs;

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 房间已关闭：退出页面后所有延迟回调（断流重试退避、在飞的
  /// 取流请求）不得再 open，否则会在已释放播放器上拉起脱缰音频
  bool _roomClosed = false;

  /// 播放会话代次：切房/刷新时递增。
  /// 所有跨越 await 的异步流程恢复执行前必须校验代次，
  /// 防止旧会话（旧房间、旧画质）的结果覆盖当前状态
  int _sessionGen = 0;

  /// 取流请求代次：每次发起取流递增，仅最后一次取流的结果生效。
  /// 快速连续切画质/刷新时，旧请求返回不会污染播放列表
  int _playUrlGen = 0;

  /// 播放纪元：用户主动操作（切线路/成功取流）会递增，
  /// 退避等待中的断流恢复据此自动作废
  int _playbackEpoch = 0;

  /// 断流恢复任务：同一时刻只允许一个恢复流程运行，
  /// 窗口内到达的 error/completed 重复事件被合并；
  /// 恢复失败会由播放器再次产生事件驱动下一轮
  Future<void>? _recoveryTask;

  /// 会话是否仍然有效
  bool _sessionAlive(int gen) => gen == _sessionGen && !_roomClosed;

  /// 是否处于后台
  var isBackground = false;

  var datetime = "00:00".obs;

  final List<Pattern> _shieldPatterns = <Pattern>[];
  Worker? _shieldPatternWorker;

  /// 时钟定时器：必须持有引用并在 onClose 取消，
  /// 否则每秒回调会长期持有已释放的 Controller
  Timer? _clockTimer;

  /// 弹幕批量提交：高频房间逐条 addDanmaku 会造成绘制突发，
  /// 与手机端一致按 120ms 批量刷新
  final List<DanmakuContentItem> _pendingDanmaku = <DanmakuContentItem>[];
  Timer? _danmakuFlushTimer;
  static const Duration _danmakuFlushInterval = Duration(milliseconds: 120);

  /// 弹幕显示预算：待显示队列与单批次提交上限，
  /// 高热房间过载时丢弃旧弹幕，优先保视频播放
  static const int _maxPendingDanmaku = 400;
  static const int _maxDanmakuPerFlush = 60;

  /// 弹幕丢弃节流提示：高热房间过载时让用户感知降级发生
  DateTime? _lastDropNoticeAt;
  static const Duration _dropNoticeInterval = Duration(seconds: 10);

  void _notifyDanmakuDropped() {
    final last = _lastDropNoticeAt;
    final now = DateTime.now();
    if (last != null && now.difference(last) < _dropNoticeInterval) return;
    _lastDropNoticeAt = now;
    SmartDialog.showToast("弹幕量过大，已跳过部分显示");
  }

  /// 首帧链路分阶段计时与恢复统计：为调参提供实测数据
  final Stopwatch _loadStopwatch = Stopwatch();
  int? _detailMs;
  int? _qualitesMs;
  int? _playUrlMs;
  DateTime? _openIssuedAt;
  bool _firstFrameLogged = false;
  bool _recovering = false;

  /// 整轮恢复的总时间预算：断流事件起的截止时间，
  /// 防止退避+换线+刷新的长尾组合无限消耗
  DateTime? _recoveryDeadline;
  static const Duration _recoveryBudget = Duration(seconds: 90);

  /// 稳定播放计时：持续播放满 60 秒才重置重试预算，
  /// 闪断救活不应持续消耗预算，但真·稳定后要能恢复预算
  Timer? _stablePlayTimer;
  static const Duration _stablePlayThreshold = Duration(minutes: 1);

  void initTimer() {
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      var now = DateTime.now();
      datetime.value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    });
  }

  /// 双击退出Flag
  bool doubleClickExit = false;

  /// 双击退出Timer
  Timer? doubleClickTimer;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    initTimer();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    _initShieldPatterns();

    loadData();

    super.onInit();
  }

  void _initShieldPatterns() {
    _rebuildShieldPatterns();
    _shieldPatternWorker?.dispose();
    _shieldPatternWorker = ever(
      AppSettingsController.instance.shieldList,
      (_) => _rebuildShieldPatterns(),
    );
  }

  void _rebuildShieldPatterns() {
    _shieldPatterns.clear();
    for (var keyword in AppSettingsController.instance.shieldList) {
      if (Utils.isRegexFormat(keyword)) {
        final removedSlash = Utils.removeRegexFormat(keyword);
        try {
          _shieldPatterns.add(RegExp(removedSlash));
        } catch (e) {
          Log.d("关键词：$keyword 正则格式错误");
        }
      } else {
        _shieldPatterns.add(keyword);
      }
    }
  }

  bool _containsBlockedKeyword(String message) {
    for (var pattern in _shieldPatterns) {
      if (message.contains(pattern)) {
        return true;
      }
    }
    return false;
  }

  void refreshRoom() {
    //messages.clear();

    liveDanmaku.stop();

    loadData();
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      if (_containsBlockedKeyword(msg.message)) {
        return;
      }

      if (liveStatus.value != LiveStatus.live || isBackground) {
        return;
      }

      if (_pendingDanmaku.length < _maxPendingDanmaku) {
        _pendingDanmaku.add(
          DanmakuContentItem(
            msg.message,
            color: Color.fromARGB(255, msg.color.r, msg.color.g, msg.color.b),
          ),
        );
      } else {
        LiveMetrics.instance.recordDanmakuDrop(1);
        _notifyDanmakuDropped();
      }
      _scheduleDanmakuFlush();
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      //superChats.add(msg.data);
    }
  }

  void _scheduleDanmakuFlush() {
    _danmakuFlushTimer ??= Timer(_danmakuFlushInterval, _flushPendingDanmaku);
  }

  void _flushPendingDanmaku() {
    _danmakuFlushTimer = null;
    if (_pendingDanmaku.isEmpty) return;
    List<DanmakuContentItem> batch;
    if (_pendingDanmaku.length > _maxDanmakuPerFlush) {
      // 超载：只提交最新的 N 条，丢弃已失去时效的旧弹幕
      LiveMetrics.instance
          .recordDanmakuDrop(_pendingDanmaku.length - _maxDanmakuPerFlush);
      _notifyDanmakuDropped();
      batch =
          _pendingDanmaku.sublist(_pendingDanmaku.length - _maxDanmakuPerFlush);
    } else {
      batch = List<DanmakuContentItem>.from(_pendingDanmaku);
    }
    addDanmaku(batch);
    _pendingDanmaku.clear();
  }

  /// 加载直播间信息
  void loadData() async {
    // 开启新的播放会话：此前一切在飞请求与恢复任务作废
    final gen = ++_sessionGen;
    // 分阶段计时归零：detail→画质→取流→open→首帧
    _loadStopwatch
      ..reset()
      ..start();
    _detailMs = null;
    _qualitesMs = null;
    _playUrlMs = null;
    _firstFrameLogged = false;
    _recovering = false;
    _recoveryDeadline = null;
    _stablePlayTimer?.cancel();
    try {
      SmartDialog.showLoading(msg: "");
      pageLoadding.value = true;
      // 斗鱼预热播放签名：与 getRoomDetail 并行，首帧省一个 RTT
      if (site.liveSite is DouyuSite) {
        unawaited((site.liveSite as DouyuSite).warmPlayArgs(roomId));
      }
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);
      if (!_sessionAlive(gen)) return;
      _detailMs = _loadStopwatch.elapsedMilliseconds;
      _reResolveTimes.clear();

      addHistory();
      online.value = detail.value!.online;
      liveStatus.value = (detail.value!.status || detail.value!.isRecord)
          ? LiveStatus.live
          : LiveStatus.offline;
      if (liveStatus.value == LiveStatus.live) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        SmartDialog.showToast("当前主播未开播，正在轮播录像");
      }

      initDanmau();
      // 弹幕参数可能是异步解析中的 Future（如B站），连接失败只降级弹幕
      unawaited(
        liveDanmaku.start(detail.value?.danmakuData).catchError((e) {
          Log.logPrint(e);
        }),
      );
    } catch (e) {
      if (!_sessionAlive(gen)) return;
      SmartDialog.showToast(e.toString());
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
      pageLoadding.value = false;
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    final gen = _sessionGen;
    qualites.clear();
    currentQuality = -1;
    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);
      if (!_sessionAlive(gen)) return;
      _qualitesMs = _loadStopwatch.elapsedMilliseconds;

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      // 画质列表整体替换，在飞的取流请求作废
      _playUrlGen++;
      qualites.value = playQualites;
      var qualityLevel = AppSettingsController.instance.qualityLevel.value;
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      unawaited(getPlayUrl());
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  /// 取流并重建播放列表，返回是否成功。
  /// 取流失败时保留旧线路，供断流重试兜底。
  Future<bool> getPlayUrl() async {
    final gen = _sessionGen;
    final req = ++_playUrlGen;
    final qualityIndex = currentQuality;
    if (qualityIndex < 0 || qualityIndex >= qualites.length) {
      return false;
    }
    // 快照本次请求的画质对象：跨 await 后 currentQuality 可能
    // 已被用户修改，显示的清晰度必须与实际取流一致
    final quality = qualites[qualityIndex];
    try {
      var playUrl = await site.liveSite
          .getPlayUrls(detail: detail.value!, quality: quality);
      // 会话已结束，或存在更新的取流请求：丢弃本次结果
      if (!_sessionAlive(gen) || req != _playUrlGen) return false;
      if (playUrl.urls.isEmpty) {
        SmartDialog.showToast("无法读取播放地址");
        return false;
      }
      playUrls.clear();
      currentQualityInfo.value = quality.quality;
      currentLineInfo.value = "";
      currentLineIndex = -1;
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
      currentLineIndex = 0;
      currentLineInfo.value = "线路${currentLineIndex + 1}";
      //重置错误次数
      mediaErrorRetryCount = 0;
      _playbackEpoch++;
      _playUrlMs = _loadStopwatch.elapsedMilliseconds;
      setPlayer();
      return true;
    } catch (e) {
      Log.logPrint(e);
      if (_sessionAlive(gen) && req == _playUrlGen) {
        SmartDialog.showToast("读取播放地址失败");
      }
      return false;
    }
  }

  void changePlayLine(int index) {
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    // 用户主动换线：退避等待中的断流恢复作废
    _playbackEpoch++;
    setPlayer();
  }

  void setPlayer() async {
    final gen = _sessionGen;
    final req = _playUrlGen;
    if (!_sessionAlive(gen)) return;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";
    try {
      // 初始化播放器并设置 ao 参数
      await initializePlayer();
      // 初始化期间取流请求可能已被更新的一次取代
      if (!_sessionAlive(gen) || req != _playUrlGen) return;
      // 取流结果可能刚被替换：线路索引越界时回退首条
      if (currentLineIndex < 0 || currentLineIndex >= playUrls.length) {
        currentLineIndex = 0;
      }
      _openIssuedAt = DateTime.now();
      player.open(
        Media(
          playUrls[currentLineIndex],
          httpHeaders: playHeaders,
        ),
      );

      Log.d("播放链接\r\n：${playUrls[currentLineIndex]}");
    } catch (e) {
      // setPlayer 多以 unawaited 方式调用，错误必须就地消化
      Log.logPrint(e);
    }
  }

  /// 断流事件统一入口：error 与 completed 可能为同一次故障连续
  /// 触发，经 _recoveryTask 合并为单轮恢复流程
  void _onPlaybackFailure(String reason, {String? error}) {
    if (_roomClosed) return;
    if (!_recovering) {
      _recovering = true;
      _recoveryDeadline = DateTime.now().add(_recoveryBudget);
    }
    // 播放已不再稳定：挂起的预算重置作废
    _stablePlayTimer?.cancel();
    _recoveryTask ??= _runRecovery(reason, error: error)
        .whenComplete(() => _recoveryTask = null);
  }

  /// 单轮恢复：先在当前流上退避重试；预算耗尽后进入
  /// 换线路 / 状态核实 / 刷新流信息的兜底流程
  Future<void> _runRecovery(String reason, {String? error}) async {
    final gen = _sessionGen;
    if (mediaErrorRetryCount < 2) {
      // 决策时即刻消耗重试预算，避免并发事件重复排队
      mediaErrorRetryCount += 1;
      final delay =
          Duration(milliseconds: 500 * (1 << (mediaErrorRetryCount - 1)));
      Log.d("$reason，${delay.inMilliseconds}ms 后尝试第$mediaErrorRetryCount次刷新");
      final epoch = _playbackEpoch;
      await Future.delayed(delay);
      // 退避期间用户退出/切房/手动操作：本次恢复作废
      if (!_sessionAlive(gen) || epoch != _playbackEpoch) return;
      // 整轮恢复的总时间预算耗尽：直接进入终态核实，不再消耗重试
      if (_recoveryDeadlineExceeded) {
        await _playbackRetriesExhausted(gen: gen, error: error);
        return;
      }
      LiveMetrics.instance.recordRecoveryAttempt();
      if (site.id == Constant.kDouyu) {
        // 斗鱼签名带时间戳、播放地址带 expire 时效：重试需重新取流，
        // 重放旧地址会被服务端掐断。getPlayUrl 内部会重置重试计数，需还原
        final retryCount = mediaErrorRetryCount;
        final ok = await getPlayUrl();
        if (!ok && playUrls.isNotEmpty && currentLineIndex >= 0) {
          setPlayer();
        }
        mediaErrorRetryCount = retryCount;
      } else {
        setPlayer();
      }
      return;
    }
    Log.d("$reason，本线路重试耗尽");
    await _playbackRetriesExhausted(gen: gen, error: error);
  }

  @override
  void mediaEnd() {
    super.mediaEnd();
    Log.d("播放结束");
    _onPlaybackFailure("播放结束");
  }

  int mediaErrorRetryCount = 0;

  /// 断流后"仍在播→重新取流"的兜底记账：防止周期性被掐流的
  /// 房间无限重试空转
  final List<DateTime> _reResolveTimes = [];
  static const int _maxReResolvePerWindow = 6;
  static const Duration _reResolveWindow = Duration(minutes: 10);

  bool get _reResolveStormExceeded {
    final cutoff = DateTime.now().subtract(_reResolveWindow);
    _reResolveTimes.removeWhere((t) => t.isBefore(cutoff));
    return _reResolveTimes.length >= _maxReResolvePerWindow;
  }

  /// 重试耗尽后的兜底：先核实真实开播状态，仍在播就重置计数
  /// 刷新流信息再试一轮；确实下播才标记未开播。
  /// "重试耗尽"不等于"下播"——服务端掐流后重试同样会被掐，
  /// 直接判下播会误报（斗鱼匿名高画质约十分钟断流就是这种情况）；
  /// 状态查询失败属于"未知"而非"未开播"，只提示连接失败
  Future<void> _playbackRetriesExhausted(
      {required int gen, String? error}) async {
    if (!_sessionAlive(gen)) return;
    if (playUrls.length - 1 != currentLineIndex) {
      LiveMetrics.instance.recordRecoveryAttempt();
      changePlayLine(currentLineIndex + 1);
      return;
    }
    LiveRoomDetail? freshDetail;
    bool? stillLive;
    try {
      // 直接拉详情：一次请求同时得到开播状态与刷新流信息
      // 所需的全部数据，避免"状态查询+详情刷新"两次全量请求
      freshDetail = await site.liveSite.getRoomDetail(roomId: roomId);
      stillLive = freshDetail.status || freshDetail.isRecord;
    } catch (_) {
      // 详情拉取失败时退化为轻量状态查询
      try {
        stillLive = await site.liveSite.getLiveStatus(roomId: roomId);
      } catch (_) {}
    }
    if (!_sessionAlive(gen)) return;
    if (stillLive == true &&
        !_reResolveStormExceeded &&
        !_recoveryDeadlineExceeded) {
      _reResolveTimes.add(DateTime.now());
      Log.d("重试耗尽但房间仍在播，刷新流信息再试一轮");
      currentLineIndex = 0;
      mediaErrorRetryCount = 0;
      LiveMetrics.instance.recordRecoveryAttempt();
      if (await _refreshStreamInfo(gen, prefetched: freshDetail)) {
        return;
      }
      if (!_sessionAlive(gen)) return;
      // 刷新确认房间已下播（内部已标记 offline）
      if (liveStatus.value == LiveStatus.offline) {
        _endRecovery(succeeded: false);
        return;
      }
      // 仍在播但无法恢复：报播放失败，不谎报下播
      errorMsg.value = "播放失败";
      if (error != null) {
        SmartDialog.showToast("播放失败:$error");
      }
      _endRecovery(succeeded: false);
      return;
    }
    if (stillLive == null) {
      // 无法确认直播状态：保留现有状态，提示连接失败，
      // 等待下一轮断流事件或用户手动刷新
      errorMsg.value = "无法确认直播状态，请检查网络后重试";
      SmartDialog.showToast(errorMsg.value);
      _endRecovery(succeeded: false);
      return;
    }
    liveStatus.value = LiveStatus.offline;
    if (error != null) {
      errorMsg.value = "播放失败";
      SmartDialog.showToast("播放失败:$error");
    }
    _endRecovery(succeeded: false);
  }

  /// 恢复预算是否已超总时限
  bool get _recoveryDeadlineExceeded =>
      _recoveryDeadline != null &&
      DateTime.now().isAfter(_recoveryDeadline!);

  /// 一轮恢复终结记账：重新起播由 onPlayingStarted 记成功，
  /// 这里处理进入终态的路径
  void _endRecovery({required bool succeeded}) {
    if (!_recovering) return;
    _recovering = false;
    _recoveryDeadline = null;
    LiveMetrics.instance.recordRecoveryEnd(succeeded: succeeded);
  }

  /// 播放器进入播放态：记录 open→playing 耗时；
  /// 处于恢复流程中时同时记一次恢复成功
  @override
  void onPlayingStarted() {
    final issued = _openIssuedAt;
    if (issued == null) return;
    _openIssuedAt = null;
    final openMs = DateTime.now().difference(issued).inMilliseconds;
    _endRecovery(succeeded: true);
    // 稳定播放满阈值后重置重试预算：靠重开流救活的房间
    // 若长期稳定播放，下一次故障应拥有完整预算
    _stablePlayTimer?.cancel();
    _stablePlayTimer = Timer(_stablePlayThreshold, () {
      mediaErrorRetryCount = 0;
    });
    if (!_firstFrameLogged) {
      _firstFrameLogged = true;
      Log.i(
        '首帧链路: detail=${_detailMs}ms qualites=${_qualitesMs}ms '
        'playUrl=${_playUrlMs}ms open->playing=${openMs}ms '
        'total=${_loadStopwatch.elapsedMilliseconds}ms',
      );
    } else {
      Log.i('恢复起播: open->playing=${openMs}ms');
    }
  }

  /// 刷新房间流信息：重新拉取详情与画质列表，尽量保住用户已选
  /// 画质，再重新取流。与"重连当前地址"是不同语义——用于
  /// 地址/签名整体失效后的恢复（抖音旧地址失效是典型场景）
  Future<bool> _refreshStreamInfo(int gen,
      {LiveRoomDetail? prefetched}) async {
    try {
      final freshDetail =
          prefetched ?? await site.liveSite.getRoomDetail(roomId: roomId);
      if (!_sessionAlive(gen)) return false;
      detail.value = freshDetail;
      if (!(freshDetail.status || freshDetail.isRecord)) {
        liveStatus.value = LiveStatus.offline;
        return false;
      }
      // 记录用户当前选择的画质名，刷新后按名匹配
      final prevQualityName =
          currentQuality >= 0 && currentQuality < qualites.length
              ? qualites[currentQuality].quality
              : null;
      final freshQualities =
          await site.liveSite.getPlayQualites(detail: freshDetail);
      if (!_sessionAlive(gen)) return false;
      if (freshQualities.isEmpty) return false;
      // 画质列表整体替换，在飞的取流请求作废
      _playUrlGen++;
      qualites.value = freshQualities;
      final next =
          freshQualities.indexWhere((q) => q.quality == prevQualityName);
      currentQuality = next >= 0 ? next : 0;
      return await getPlayUrl();
    } catch (e) {
      Log.logPrint(e);
      return false;
    }
  }

  @override
  void mediaError(String error) {
    super.mediaError(error);
    _onPlaybackFailure("播放失败", error: error);
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已关注");
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    // if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
    //   return;
    // }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    SmartDialog.showToast("已取消关注");
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    // 作废旧房间的一切在飞请求与断流恢复
    _sessionGen++;
    _playUrlGen++;
    _playbackEpoch++;

    rxSite.value = site;
    rxRoomId.value = roomId;

    // 清除全部消息
    liveDanmaku.stop();
    _danmakuFlushTimer?.cancel();
    _danmakuFlushTimer = null;
    _pendingDanmaku.clear();

    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  void nextChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels
        .indexWhere((element) => element.id == "${site.id}_$roomId");
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index += 1;
    if (index >= liveChannels.length) {
      index = 0;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
  }

  void prevChannel() {
    //读取正在直播的频道
    var liveChannels = FollowUserService.instance.livingList;
    if (liveChannels.isEmpty) {
      SmartDialog.showToast("没有正在直播的频道");
      return;
    }
    var index = liveChannels
        .indexWhere((element) => element.id == "${site.id}_$roomId");
    // if (index == -1) {
    //   //当前频道不在列表中

    //   return;
    // }
    index -= 1;
    if (index < 0) {
      index = liveChannels.length - 1;
    }
    var nextChannel = liveChannels[index];

    resetRoom(Sites.allSites[nextChannel.siteId]!, nextChannel.roomId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
    }
  }

  @override
  void onClose() {
    _roomClosed = true;
    _sessionGen++;
    WidgetsBinding.instance.removeObserver(this);
    _clockTimer?.cancel();
    _clockTimer = null;
    _danmakuFlushTimer?.cancel();
    _danmakuFlushTimer = null;
    _stablePlayTimer?.cancel();
    _pendingDanmaku.clear();
    liveDanmaku.stop();
    _shieldPatternWorker?.dispose();
    _shieldPatternWorker = null;

    danmakuController = null;
    super.onClose();
  }
}
