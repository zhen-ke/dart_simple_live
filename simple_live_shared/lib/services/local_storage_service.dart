import 'dart:async';

import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_shared/app/log.dart';

class LocalStorageService extends GetxService {
  LocalStorageService({
    this.settingsBoxName = "LocalStorage",
    this.shieldBoxName = "DanmuShield",
  });

  /// box 名可注入：TV 沿用历史的 TV* 前缀名，避免升级丢数据
  final String settingsBoxName;
  final String shieldBoxName;

  static LocalStorageService get instance => Get.find<LocalStorageService>();

  /// 首次运行
  static const String kFirstRun = "FirstRun";

  /// 缩放模式
  static const String kPlayerScaleMode = "ScaleMode";

  /// 网站排序
  static const String kSiteSort = "SiteSort";

  /// 首页排序
  static const String kHomeSort = "HomeSort";

  /// 显示模式
  /// * [0] 跟随系统
  /// * [1] 浅色模式
  /// * [2] 深色模式
  static const String kThemeMode = "ThemeMode";

  /// DEBUG模式
  static const String kDebugModeKey = "DebugMode";

  /// 弹幕大小
  static const String kDanmuSize = "DanmuSize";

  /// 弹幕速度
  static const String kDanmuSpeed = "DanmuSpeed";

  /// 弹幕区域
  static const String kDanmuArea = "DanmuArea";

  /// 弹幕透明度
  static const String kDanmuOpacity = "DanmuOpacity";

  /// 弹幕描边大小
  static const String kDanmuStrokeWidth = "DanmuStrokeWidth";

  /// 弹幕-屏蔽滚动
  static const String kDanmuHideScroll = "DanmuHideScroll";

  /// 弹幕-屏蔽底部
  static const String kDanmuHideBottom = "DanmuHideBottom";

  /// 弹幕-屏蔽顶部
  static const String kDanmuHideTop = "DanmuHideTop";

  /// 弹幕-顶部边距
  static const String kDanmuTopMargin = "DanmuTopMargin";

  /// 弹幕-底部边距
  static const String kDanmuBottomMargin = "DanmuBottomMargin";

  /// 弹幕开启
  static const String kDanmuEnable = "DanmuEnable";

  /// 弹幕字重
  static const String kDanmuFontWeight = "DanmuFontWeight";

  /// 硬件解码
  static const String kHardwareDecode = "HardwareDecode";

  /// 聊天区文字大小
  static const String kChatTextSize = "ChatTextSize";

  /// 聊天区间隔
  static const String kChatTextGap = "ChatTextGap";

  /// 聊天区-气泡样式
  static const String kChatBubbleStyle = "ChatBubbleStyle";

  /// 播放清晰度，0=低，1=中，2=高
  static const String kQualityLevel = "QualityLevel";

  /// 蜂窝网络下播放清晰度，0=低，1=中，2=高
  static const String kQualityLevelCellular = "QualityLevelCellular";

  /// 开启定时关闭
  static const String kAutoExitEnable = "AutoExitEnable";

  /// 定时关闭时间（分钟）
  static const String kAutoExitDuration = "AutoExitDuration";

  /// 房间内定时关闭时间（分钟）
  /// 需要一个不同的 key，因为用户在房间内设置的倒计时和全局的可能不同。
  static const String kRoomAutoExitDuration = "RoomAutoExitDuration";

  /// 播放器兼容模式
  static const String kPlayerCompatMode = "PlayerCompatMode";

  /// 播放器后台自动暂停
  static const String kPlayerAutoPause = "PlayerAutoPause";

  /// 播放器缓冲区大小
  static const String kPlayerBufferSize = "PlayerBufferSize";

  /// 播放器强制使用HTTPS
  static const String kPlayerForceHttps = "PlayerForceHttps";

  /// 播放线路策略
  /// * [0] 低延迟优先（FLV优先）
  /// * [1] 稳定优先（HLS优先）
  static const String kPlayerLineStrategy = "PlayerLineStrategy";

  /// 自动全屏
  static const String kAutoFullScreen = "AutoFullScreen";

  /// 显示SC
  static const String kPlayerShowSuperChat = "PlayerShowSuperChat";

  /// 播放器音量
  static const String kPlayerVolume = "PlayerVolume";

  /// 小窗隐藏弹幕
  static const String kPIPHideDanmu = "PIPHideDanmu";

  /// 哔哩哔哩cookie
  static const String kBilibiliCookie = "BilibiliCookie";

  /// 抖音cookie
  static const String kDouyinCookie = "DouyinCookie";

  /// 斗鱼匿名设备号（32位hex，每设备持久化一份，避免共享did被风控掐流）
  static const String kDouyuDeviceId = "DouyuDeviceId";

  /// 斗鱼cookie
  static const String kDouyuCookie = "DouyuCookie";

  ///主题色
  static const String kStyleColor = "kStyleColor";

  ///动态取色
  static const String kIsDynamic = "kIsDynamic";

  /// 提示哔哩哔哩登录
  static const String kBilibiliLoginTip = "BilibiliLoginTip";

  /// 日志记录
  static const String kLogEnable = "LogEnable";

  /// 开启自定义播放器视频输出
  static const String kCustomPlayerOutput = "CustomPlayerOutput";

  /// 视频输出驱动
  static const String kVideoOutputDriver = "VideoOutputDriver";

  /// 视频硬件解码器
  static const String kVideoHardwareDecoder = "VideoHardwareDecoder";

  /// 音频输出驱动
  static const String kAudioOutputDriver = "AudioOutputDriver";

  /// 开启自动更新关注
  static const String kAutoUpdateFollowEnable = "AutoUpdateFollowEnable";

  /// 定时自动更新关注间隔（分钟）
  static const String kUpdateFollowDuration = "AutoUpdateFollowDuration";

  /// 开启多线程更新关注
  static const String kUpdateFollowThreadCount = "UpdateFollowThreadCount";

  /// WebDAV_服务器地址
  static const String kWebDAVUri = "WebDAVUri";

  /// WebDAV_登录账号
  static const String kWebDAVUser = "WebDAVUser";

  /// WebDAV_登录密码
  static const String kWebDAVPassword = "kWebDAVPassword";

  /// WebDAV_最后一次上传时间
  static const String kWebDAVLastUploadTime = "kWebDAVLastUploadTime";

  /// WebDAV_最后一次备份时间
  static const String kWebDAVLastRecoverTime = "kWebDAVLastRecoverTime";

  /// 日志中必须脱敏的键：账号 Cookie、WebDAV 凭据、设备身份。
  /// 取两端超集：TV 端此前漏掉了斗鱼设备号，会在日志里明文打出
  static const Set<String> sensitiveKeys = {
    kBilibiliCookie,
    kDouyinCookie,
    kDouyuCookie,
    kDouyuDeviceId,
    kWebDAVUri,
    kWebDAVUser,
    kWebDAVPassword,
  };

  /// 仅属于本机、不进入 WebDAV/配置备份的键。
  /// 账号会话、设备身份、WebDAV 连接信息一旦跨设备复制，
  /// 既可能造成串号，也会把凭据带进备份文件。
  static const Set<String> localOnlyKeys = {
    kFirstRun,
    kLogEnable,
    kDouyuDeviceId,
    kBilibiliCookie,
    kDouyinCookie,
    kDouyuCookie,
    kWebDAVUri,
    kWebDAVUser,
    kWebDAVPassword,
    kWebDAVLastUploadTime,
    kWebDAVLastRecoverTime,
  };

  late Box settingsBox;
  late Box<String> shieldBox;

  Future init() async {
    // 两个 box 互不依赖，并行打开
    final settingsFuture = Hive.openBox(settingsBoxName);
    final shieldFuture = Hive.openBox<String>(shieldBoxName);
    settingsBox = await settingsFuture;
    shieldBox = await shieldFuture;
  }

  /// 可进入备份/导出的设置快照。
  Map<String, dynamic> exportableSettings() {
    final result = <String, dynamic>{};
    settingsBox.toMap().forEach((key, value) {
      if (key is String && !localOnlyKeys.contains(key)) {
        result[key] = value;
      }
    });
    return result;
  }

  /// 用备份中的设置覆盖本地，但保留 [localOnlyKeys]：
  /// 恢复别人的备份不应该把本机 WebDAV 登录状态、设备号或账号会话一起替换掉。
  Future<void> restoreSettings(Map<String, dynamic> data) async {
    final localValues = <String, dynamic>{};
    for (final key in localOnlyKeys) {
      if (settingsBox.containsKey(key)) {
        localValues[key] = settingsBox.get(key);
      }
    }

    final incoming = Map<String, dynamic>.from(data)
      ..removeWhere((key, _) => localOnlyKeys.contains(key));

    await settingsBox.clear();
    if (incoming.isNotEmpty) {
      await settingsBox.putAll(incoming);
    }
    if (localValues.isNotEmpty) {
      await settingsBox.putAll(localValues);
    }
  }

  T getValue<T>(dynamic key, T defaultValue) {
    try {
      var value = settingsBox.get(key, defaultValue: defaultValue) as T;
      if (sensitiveKeys.contains(key)) {
        Log.d("Get LocalStorage：$key [redacted]");
      } else {
        Log.d("Get LocalStorage：$key\r\n$value");
      }
      return value;
    } catch (e) {
      Log.logPrint(e);
      return defaultValue;
    }
  }

  /// 写入设置项。
  ///
  /// 设置是"发完就不管"的持久化：全仓没有任何调用方 await 它，
  /// 也没有可恢复的失败路径。返回 Future 只会制造"可以等待"的错觉，
  /// 因此签名就是 void，内部显式 unawaited 表达忽略意图。
  void setValue<T>(dynamic key, T value) {
    if (sensitiveKeys.contains(key)) {
      Log.d("Set LocalStorage：$key [redacted]");
    } else {
      Log.d("Set LocalStorage：$key\r\n$value");
    }
    unawaited(settingsBox.put(key, value));
  }
}
