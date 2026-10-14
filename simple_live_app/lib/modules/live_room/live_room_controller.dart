import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  static const int _trimKeepAutoScroll = 240;
  static const int _trimTriggerAutoScroll = 320;
  static const int _trimKeepManualScroll = 800;
  static const int _trimTriggerManualScroll = 1000;
  static const Duration _chatFlushInterval = Duration(milliseconds: 120);

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
    // 抖音应该默认是竖屏的
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  /// 开播状态三态：查询失败是 unknown，不能与 offline 混为一谈
  var liveStatus = LiveStatus.unknown.obs;
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();

  /// 滚动控制
  final ScrollController scrollController = ScrollController();

  /// 聊天信息
  List<LiveMessage> messages = <LiveMessage>[];
  final List<LiveMessage> _pendingMessages = <LiveMessage>[];
  final List<DanmakuContentItem> _pendingDanmaku = <DanmakuContentItem>[];
  final List<Pattern> _shieldPatterns = <Pattern>[];
  Timer? _chatFlushTimer;
  Worker? _shieldPatternWorker;

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
    addSysMsg("弹幕量过大，已跳过部分显示");
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
  /// 取流请求）不得再 open/jump，否则会在已释放播放器上拉起脱缰音频
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

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用自动滚动聊天栏
  /// - 当用户向上滚动聊天栏时，不再自动滚动
  var disableAutoScroll = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 直播间加载失败
  var loadError = false.obs;
  Object? error;
  StackTrace? errorStackTrace;

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;

  /// SC 清理定时器：过期与数量上限由数据层负责，
  /// 不依赖懒加载卡片的 onExpire（用户不打开 SC 页时仍生效）
  Timer? _scPruneTimer;
  static const int _maxSuperChats = 50;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    _initShieldPatterns();
    _scPruneTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => removeSuperChats(),
    );
    loadData();

    scrollController.addListener(scrollListener);

    super.onInit();
  }

  void scrollListener() {
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      disableAutoScroll.value = true;
    }
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

  void _scheduleChatFlush() {
    if (_chatFlushTimer != null) {
      return;
    }
    _chatFlushTimer = Timer(_chatFlushInterval, _flushPendingMessages);
  }

  void _flushPendingMessages() {
    _chatFlushTimer?.cancel();
    _chatFlushTimer = null;

    if (_pendingMessages.isNotEmpty) {
      messages.addAll(_pendingMessages);
      _pendingMessages.clear();
      _trimMessagesIfNeeded();

      update(['chatList']);

      if (!disableAutoScroll.value) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => chatScrollToBottom(),
        );
      }
    }

    if (_pendingDanmaku.isNotEmpty) {
      List<DanmakuContentItem> batch;
      if (_pendingDanmaku.length > _maxDanmakuPerFlush) {
        // 超载：只提交最新的 N 条，丢弃已失去时效的旧弹幕
        LiveMetrics.instance
            .recordDanmakuDrop(_pendingDanmaku.length - _maxDanmakuPerFlush);
        _notifyDanmakuDropped();
        batch = _pendingDanmaku
            .sublist(_pendingDanmaku.length - _maxDanmakuPerFlush);
      } else {
        batch = List<DanmakuContentItem>.from(_pendingDanmaku);
      }
      addDanmaku(batch);
      _pendingDanmaku.clear();
    }
  }

  void _trimMessagesIfNeeded() {
    if (disableAutoScroll.value) {
      if (messages.length > _trimTriggerManualScroll) {
        messages.removeRange(0, messages.length - _trimKeepManualScroll);
      }
    } else if (messages.length > _trimTriggerAutoScroll) {
      messages.removeRange(0, messages.length - _trimKeepAutoScroll);
    }
  }

  void _clearPendingMessages() {
    _chatFlushTimer?.cancel();
    _chatFlushTimer = null;
    _pendingMessages.clear();
    _pendingDanmaku.clear();
  }

  int _streamTypePriority(String url, bool preferHls) {
    final lower = url.toLowerCase();
    final isFlv = lower.contains('.flv');
    final isHls = lower.contains('.m3u8');

    if (preferHls) {
      if (isHls) return 0;
      if (isFlv) return 1;
    } else {
      if (isFlv) return 0;
      if (isHls) return 1;
    }
    return 2;
  }

  List<String> _reorderPlayUrlsByStrategy(List<String> urls) {
    final preferHls = AppSettingsController.instance.playerLineStrategy.value == 1;
    final entries = urls.asMap().entries.toList();
    entries.sort((a, b) {
      final pa = _streamTypePriority(a.value, preferHls);
      final pb = _streamTypePriority(b.value, preferHls);
      if (pa != pb) {
        return pa - pb;
      }
      return a.key - b.key;
    });
    return entries.map((entry) => entry.value).toList();
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        timer = Timer(const Duration(seconds: 10), () async {
          await WakelockPlus.disable();
          exit(0);
        });
        autoExitTimer?.cancel();
        var delay = await Utils.showAlertDialog("定时关闭已到时,是否延迟关闭?",
            title: "延迟关闭", confirm: "延迟", cancel: "关闭", selectable: true);
        if (delay) {
          timer.cancel();
          delayAutoExit.value = true;
          showAutoExitSheet();
          setAutoExit();
        } else {
          delayAutoExit.value = false;
          await WakelockPlus.disable();
          exit(0);
        }
      }
    });
  }
  // 弹窗逻辑

  void refreshRoom() {
    //messages.clear();
    superChats.clear();
    _clearPendingMessages();
    liveDanmaku.stop();

    loadData();
  }

  /// 聊天栏始终滚动到底部
  void chatScrollToBottom() {
    if (scrollController.hasClients) {
      // 如果手动上拉过，就不自动滚动到底部
      if (disableAutoScroll.value) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      if (_containsBlockedKeyword(msg.message)) {
        return;
      }

      _pendingMessages.add(msg);

      if (liveStatus.value == LiveStatus.live &&
          !isBackground &&
          showDanmakuState.value) {
        if (_pendingDanmaku.length < _maxPendingDanmaku) {
          _pendingDanmaku.add(
            DanmakuContentItem(
              msg.message,
              color: Color.fromARGB(
                255,
                msg.color.r,
                msg.color.g,
                msg.color.b,
              ),
            ),
          );
        } else {
          LiveMetrics.instance.recordDanmakuDrop(1);
          _notifyDanmakuDropped();
        }
      }
      _scheduleChatFlush();
    } else if (msg.type == LiveMessageType.online) {
      if (online.value != msg.data) {
        online.value = msg.data;
      }
    } else if (msg.type == LiveMessageType.superChat) {
      superChats.add(msg.data);
    }
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    messages.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: msg,
        color: LiveMessageColor.white,
      ),
    );
    _trimMessagesIfNeeded();
  }

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket准备就绪
  void onWSReady() {
    addSysMsg("弹幕服务器连接正常");
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
      loadError.value = false;
      error = null;
      errorStackTrace = null;
      update();
      addSysMsg("正在读取直播间信息");
      // 斗鱼预热播放签名：与 getRoomDetail 并行，首帧省一个 RTT
      if (site.liveSite is DouyuSite) {
        unawaited((site.liveSite as DouyuSite).warmPlayArgs(roomId));
      }
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);
      if (!_sessionAlive(gen)) return;
      _detailMs = _loadStopwatch.elapsedMilliseconds;
      _reResolveTimes.clear();

      if (site.id == Constant.kDouyin) {
        // 1.6.0之前收藏的WebRid
        // 1.6.0收藏的RoomID
        // 1.6.0之后改回WebRid
        if (detail.value!.roomId != roomId) {
          var oldId = roomId;
          rxRoomId.value = detail.value!.roomId;
          if (followed.value) {
            // 更新关注列表
            DBService.instance.deleteFollow("${site.id}_$oldId");
            DBService.instance.addFollow(
              FollowUser(
                id: "${site.id}_$roomId",
                roomId: roomId,
                siteId: site.id,
                userName: detail.value!.userName,
                face: detail.value!.userAvatar,
                addTime: DateTime.now(),
              ),
            );
          } else {
            followed.value =
                DBService.instance.getFollowExist("${site.id}_$roomId");
          }
        }
      }

      getSuperChatMessage();

      addHistory();
      // 确认房间关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      liveStatus.value = (detail.value!.status || detail.value!.isRecord)
          ? LiveStatus.live
          : LiveStatus.offline;
      if (liveStatus.value == LiveStatus.live) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在轮播录像");
      }
      addSysMsg("开始连接弹幕服务器");
      initDanmau();
      // 弹幕参数可能是异步解析中的 Future（如B站），连接失败只降级弹幕
      unawaited(
        liveDanmaku.start(detail.value?.danmakuData).catchError((e) {
          Log.logPrint(e);
          addSysMsg("弹幕服务器连接失败");
        }),
      );
      startLiveDurationTimer(); // 启动开播时长定时器
    } catch (e, s) {
      if (!_sessionAlive(gen)) return;
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      loadError.value = true;
      error = e;
      errorStackTrace = s;
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
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
      var qualityLevel = await getQualityLevel();
      if (!_sessionAlive(gen)) return;
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

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
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
      playUrls.value = _reorderPlayUrlsByStrategy(playUrl.urls);
      playHeaders = playUrl.headers;
      currentLineIndex = 0;
      currentLineInfo.value = "线路${currentLineIndex + 1}";
      //重置错误次数
      mediaErrorRetryCount = 0;
      _playbackEpoch++;
      _playUrlMs = _loadStopwatch.elapsedMilliseconds;
      initPlaylist();
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

  List<Media> _buildMediaList() {
    final forceHttps = AppSettingsController.instance.playerForceHttps.value;
    return playUrls.map((url) {
      final finalUrl =
          forceHttps ? url.replaceAll("http://", "https://") : url;
      return Media(finalUrl, httpHeaders: playHeaders);
    }).toList();
  }

  void initPlaylist() async {
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

      _openIssuedAt = DateTime.now();
      await player.open(Playlist(_buildMediaList()));
    } catch (e) {
      // initPlaylist 由 getPlayUrl 以 unawaited 方式调用，
      // 错误必须就地消化（初始化失败可重试，见 _playerInitTask）
      Log.logPrint(e);
    }
  }

  /// 重连当前线路：强制重新打开完整线路列表并跳回当前线路
  /// - 相比 player.jump，player.open 能确保 demuxer 重新拉流
  /// - 保留完整线路列表，使后续 changePlayLine 的 jump 仍可用
  Future<void> retryCurrentLine() async {
    final gen = _sessionGen;
    if (!_sessionAlive(gen)) return;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    _openIssuedAt = DateTime.now();
    await player.open(Playlist(_buildMediaList()));
    if (!_sessionAlive(gen)) return;
    if (currentLineIndex > 0) {
      await player.jump(currentLineIndex);
    }
  }

  void setPlayer() async {
    if (!_sessionAlive(_sessionGen)) return;
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    _openIssuedAt = DateTime.now();
    await player.jump(currentLineIndex);
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
          await retryCurrentLine();
        }
        mediaErrorRetryCount = retryCount;
      } else {
        await retryCurrentLine();
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

  /// 读取SC
  void getSuperChatMessage() async {
    try {
      var sc =
          await site.liveSite.getSuperChatMessage(roomId: detail.value!.roomId);
      superChats.addAll(sc);
    } catch (e) {
      Log.logPrint(e);
      addSysMsg("SC读取失败");
    }
  }

  /// 移除掉已到期的SC
  void removeSuperChats() async {
    var now = DateTime.now().millisecondsSinceEpoch;
    var alive = superChats
        .where((x) => x.endTime.millisecondsSinceEpoch > now)
        .toList();
    // 数量上限：丢弃最旧的，防止列表无界增长
    if (alive.length > _maxSuperChats) {
      alive = alive.sublist(alive.length - _maxSuperChats);
    }
    superChats.value = alive;
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
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
      return;
    }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 复制新生成的直播流
  void copyPlayUrl() async {
    // 未开播或状态未确认不复制
    if (liveStatus.value != LiveStatus.live) {
      return;
    }
    if (currentQuality < 0 || currentQuality >= qualites.length) {
      SmartDialog.showToast("播放地址尚未就绪");
      return;
    }
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链");
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => SizedBox(
              width: 200,
              child: Slider(
                min: 0,
                max: 100,
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  player.setVolume(newValue);
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: "切换清晰度",
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) {
          Get.back();
          currentQuality = e ?? 0;
          getPlayUrl();
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(
              value: i,
              title: Text(item.quality),
            );
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路",
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text("线路${i + 1}"),
              secondary: Text(
                playUrls[i].contains(".flv") ? "FLV" : "HLS",
              ),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    TextEditingController keywordController = TextEditingController();

    void addKeyword() {
      if (keywordController.text.isEmpty) {
        SmartDialog.showToast("请输入关键词");
        return;
      }

      AppSettingsController.instance
          .addShieldList(keywordController.text.trim());
      keywordController.text = "";
    }

    Utils.showBottomSheet(
      title: "关键词屏蔽",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: keywordController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词",
              suffixIcon: TextButton.icon(
                onPressed: addKeyword,
                icon: const Icon(Icons.add),
                label: const Text("添加"),
              ),
            ),
            onSubmitted: (e) {
              addKeyword();
            },
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加${AppSettingsController.instance.shieldList.length}个关键词（点击移除）",
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: AppSettingsController.instance.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        AppSettingsController.instance.removeShieldList(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(
                          item,
                          style: Get.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: Obx(
        () => Stack(
          children: [
            RefreshIndicator(
              onRefresh: FollowService.instance.loadData,
              child: ListView.builder(
                itemCount: FollowService.instance.liveList.length,
                itemBuilder: (_, i) {
                  var item = FollowService.instance.liveList[i];
                  return Obx(
                    () => FollowUserItem(
                      item: item,
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoom(
                          Sites.allSites[item.siteId]!,
                          item.roomId,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
              Positioned(
                right: 12,
                bottom: 12,
                child: Obx(
                  () => DesktopRefreshButton(
                    refreshing: FollowService.instance.updating.value,
                    onPressed: FollowService.instance.loadData,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("已设置了全局定时关闭");
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭",
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;

                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin) {
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开APP，将使用浏览器打开");
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
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
    _clearPendingMessages();
    messages.clear();
    superChats.clear();
    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
${errorStackTrace ?? (error is Error ? (error as Error).stackTrace : "")}''');
    SmartDialog.showToast("已复制错误信息");
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

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  @override
  void onClose() {
    _roomClosed = true;
    _sessionGen++;
    WidgetsBinding.instance.removeObserver(this);
    scrollController.removeListener(scrollListener);
    scrollController.dispose();
    autoExitTimer?.cancel();

    liveDanmaku.stop();
    _clearPendingMessages();
    _shieldPatternWorker?.dispose();
    _shieldPatternWorker = null;
    danmakuController = null;
    _liveDurationTimer?.cancel(); // 页面关闭时取消定时器
    _scPruneTimer?.cancel();
    _stablePlayTimer?.cancel();
    super.onClose();
  }
}
