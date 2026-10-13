import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/douyu_danmaku.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';
import 'package:crypto/crypto.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/scripts/douyu_sign.dart';

class DouyuSite implements LiveSite {
  /// 可选的登录 Cookie。匿名播放仍支持，但匿名高画质拉流可能被
  /// 服务端限时掐断（约十分钟左右）。
  String _cookie = "";
  String get cookie => _cookie;

  /// 签名参数与账号身份相关：Cookie 变更后缓存全部作废
  set cookie(String value) {
    if (_cookie != value) {
      _cookie = value;
      _freshArgsCache.clear();
    }
  }

  /// 本设备持久化的匿名设备号（32 位 hex），由 App 层生成并注入。
  /// 匿名请求不再共用写死的假 did（千万用户共享一个"设备"是风控
  /// 掐流的典型特征），签名与 dy_did/acf_did Cookie 保持一致。
  String deviceId = "";

  /// 进程内兜底设备号：App 层未注入时也保证同一进程内身份稳定。
  static final String _processFallbackDid = generateRandomString(32);

  /// V1 加密包缓存：enc_data 由服务端下发（websec/getEncryption），
  /// 客户端只计算 auth 的 MD5 链；缓存有效期取 expire_at
  Map<String, dynamic>? _encryptionData;
  String? _encryptionDid;
  Future<Map<String, dynamic>>? _encryptionFuture;

  /// 取 V1 加密包（官方 web-encrypt.js 的 _internalUpdateKey 同款逻辑）；
  /// 并发调用共享同一次请求
  Future<Map<String, dynamic>> _getEncryptionData() {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var cached = _encryptionData;
    if (cached != null &&
        _encryptionDid == _deviceDid &&
        ((cached["expire_at"] as num?)?.toInt() ?? 0) > nowSec + 60) {
      return Future.value(cached);
    }
    return _encryptionFuture ??= _fetchEncryptionData().whenComplete(() {
      _encryptionFuture = null;
    });
  }

  Future<Map<String, dynamic>> _fetchEncryptionData() async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption",
      queryParameters: {"did": _deviceDid},
      header: _requestHeaders,
    );
    if (result["error"] != 0) {
      throw CoreError("斗鱼加密包获取失败:${result["msg"]}");
    }
    _encryptionData = result["data"];
    _encryptionDid = _deviceDid;
    return _encryptionData!;
  }

  /// V1 auth 计算（官方 web-encrypt.js 的 sign(type:"stream") 同款）：
  /// u = rand_str；循环 enc_time 次 u = md5(u + key)；
  /// 最后 u = md5(u + key + rid + tt)，is_special=1 时尾段为空串
  String _computeV1Auth(Map<String, dynamic> enc, String rid, int tt) {
    final key = enc["key"].toString();
    var u = enc["rand_str"].toString();
    for (var i = 0; i < ((enc["enc_time"] as num?)?.toInt() ?? 1); i++) {
      u = md5.convert(utf8.encode(u + key)).toString();
    }
    final tail = enc["is_special"] == 1 ? "" : "$rid$tt";
    return md5.convert(utf8.encode(u + key + tail)).toString();
  }

  /// V0 接口一旦失败，本会话直接走 V1：避免每次取流都白等
  /// 一个大概率必败的 RTT（官方前端已全面迁移 V1）
  bool _preferV1 = false;

  /// 统一取流请求：先走老 getH5Play 接口，失败/异常时兜底 getH5PlayV1
  /// （官方前端已全面迁移 V1；响应 data 结构与 V0 一致）
  Future<Map> _postH5Play(
      String roomId, String args, String cdn, int rate) async {
    if (!_preferV1) {
      try {
        var result = await HttpClient.instance.postJson(
          "https://www.douyu.com/lapi/live/getH5Play/$roomId",
          data: args,
          header: {
            ..._requestHeaders,
            'referer': 'https://www.douyu.com/$roomId'
          },
          formUrlEncoded: true,
        );
        if (result["error"] == null || result["error"].toString() == "0") {
          return result;
        }
        CoreLog.w(
            "getH5Play失败(${result["error"]}:${result["msg"]})，尝试getH5PlayV1");
        _preferV1 = true;
      } catch (e) {
        CoreLog.w("getH5Play异常:$e，尝试getH5PlayV1");
        _preferV1 = true;
      }
    }
    final enc = await _getEncryptionData();
    final tt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final auth = _computeV1Auth(enc, roomId, tt);
    var postData =
        "enc_data=${Uri.encodeComponent(enc["enc_data"].toString())}"
        "&tt=$tt&did=$_deviceDid&auth=$auth"
        "&cdn=$cdn&rate=$rate&ver=Douyu_new&iar=0&ive=0&sov=0&hevc=1&fa=0";
    return HttpClient.instance.postJson(
      "https://www.douyu.com/lapi/live/getH5PlayV1/$roomId",
      data: postData,
      header: {..._requestHeaders, 'referer': 'https://www.douyu.com/$roomId'},
      formUrlEncoded: true,
    );
  }

  /// 从 cookie 字符串中解析指定键的值
  String _cookieValue(String key) {
    for (var part in cookie.split(';')) {
      var kv = part.trim().split('=');
      if (kv.length >= 2 && kv[0] == key) {
        return kv.sublist(1).join('=');
      }
    }
    return "";
  }

  /// 参与签名的设备号：优先登录 cookie 的 acf_did（与请求 Cookie
  /// 身份一致），其次 App 注入的持久化 deviceId，最后进程内随机值。
  String get _deviceDid {
    final fromCookie = _cookieValue("acf_did");
    if (fromCookie.isNotEmpty) {
      return fromCookie;
    }
    return deviceId.trim().isNotEmpty ? deviceId.trim() : _processFallbackDid;
  }

  /// 组装请求 Cookie：登录 cookie 原样保留；缺失 dy_did/acf_did 时补上
  /// 与签名一致的设备号，保证匿名请求也带稳定设备身份。
  String get _deviceCookieHeader {
    final trimmed = cookie.trim();
    final did = _deviceDid;
    var parts = <String>[];
    if (trimmed.isNotEmpty) {
      parts.add(trimmed);
    }
    if (_cookieValue("dy_did").isEmpty) {
      parts.add("dy_did=$did");
    }
    if (_cookieValue("acf_did").isEmpty) {
      parts.add("acf_did=$did");
    }
    return parts.join("; ");
  }

  Map<String, String> get _requestHeaders => {
        'referer': 'https://www.douyu.com/',
        'user-agent':
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
        'Cookie': _deviceCookieHeader,
      };

  @override
  String id = "douyu";

  @override
  String name = "斗鱼直播";

  @override
  LiveDanmaku getDanmaku() => DouyuDanmaku();

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    var result = await HttpClient.instance.getJson(
      "https://m.douyu.com/api/cate/list",
    );
    var subCateList = result["data"]["cate2Info"] as List;
    for (var item in result["data"]["cate1Info"]) {
      var cate1Id = item["cate1Id"];
      var cate1Name = item["cate1Name"];
      List<LiveSubCategory> subCategories = [];
      subCateList.where((x) => x["cate1Id"] == cate1Id).forEach((element) {
        subCategories.add(
          LiveSubCategory(
            pic: element["icon"],
            id: element["cate2Id"].toString(),
            parentId: cate1Id.toString(),
            name: element["cate2Name"].toString(),
          ),
        );
      });
      categories.add(
        LiveCategory(
          id: cate1Id.toString(),
          name: cate1Name.toString(),
          children: subCategories,
        ),
      );
    }
    // 根据ID排序
    categories.sort((a, b) => int.parse(a.id).compareTo(int.parse(b.id)));

    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/gapi/rkc/directory/mixList/2_${category.id}/$page",
      queryParameters: {},
    );

    var items = <LiveRoomItem>[];
    for (var item in result['data']['rl']) {
      if (item["type"] != 1) {
        continue;
      }
      var roomItem = LiveRoomItem(
        cover: item['rs16'].toString(),
        online: item['ol'],
        roomId: item['rid'].toString(),
        title: item['rn'].toString(),
        userName: item['nn'].toString(),
      );
      items.add(roomItem);
    }
    var hasMore = page < result['data']['pgcnt'];
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    // V1 模式不需要 V0 签名参数：跳过 homeH5Enc+签名，省一个 RTT
    var data = _preferV1
        ? ""
        : await _getFreshPlayArgs(detail.roomId, fallback: detail.data);
    data += "&cdn=&rate=-1&ver=Douyu_223061205&iar=1&ive=1&hevc=0&fa=0";
    List<LivePlayQuality> qualities = [];
    var result = await _postH5Play(detail.roomId, data, "", -1);
    if (result["error"] != null && result["error"].toString() != "0") {
      throw CoreError("斗鱼播放质量请求失败：${result["msg"] ?? result["error"]}");
    }

    var cdns = <String>[];
    for (var item in result["data"]["cdnsWithName"]) {
      cdns.add(item["cdn"].toString());
    }

    // 如果cdn以scdn开头，将其放到最后
    cdns.sort((a, b) {
      if (a.startsWith("scdn") && !b.startsWith("scdn")) {
        return 1;
      } else if (!a.startsWith("scdn") && b.startsWith("scdn")) {
        return -1;
      }
      return 0;
    });

    for (var item in result["data"]["multirates"]) {
      qualities.add(
        LivePlayQuality(
          quality: item["name"].toString(),
          data: DouyuPlayData(item["rate"], cdns),
        ),
      );
    }
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    // 签名参数带时间戳，在房间长时间停留后会过期；每次取流都重新拉
    // homeH5Enc 重新签名，而不是复用 getRoomDetail 时缓存的旧签名。
    // V1 模式不需要 V0 签名参数。
    var args = _preferV1
        ? ""
        : await _getFreshPlayArgs(detail.roomId, fallback: detail.data);
    var data = quality.data as DouyuPlayData;

    // 各 CDN 并行取地址：单条失败只丢该线路，不影响整体；
    // 比串行少等 (n-1) 个 RTT
    final results = await Future.wait(
      data.cdns.map((item) async {
        try {
          return await getPlayUrl(detail.roomId, args, data.rate, item);
        } catch (_) {
          return "";
        }
      }),
    );
    return LivePlayUrl(urls: results.where((u) => u.isNotEmpty).toList());
  }

  Future<String> getPlayUrl(
    String roomId,
    String args,
    int rate,
    String cdn,
  ) async {
    args += "&cdn=$cdn&rate=$rate";
    var result = await _postH5Play(roomId, args, cdn, rate);
    if (result["error"] != null && result["error"].toString() != "0") {
      throw CoreError("斗鱼播放地址请求失败：${result["msg"] ?? result["error"]}");
    }
    var data = result["data"];
    if (data is! Map || data["rtmp_url"] == null || data["rtmp_live"] == null) {
      throw CoreError("斗鱼返回了无效的播放地址");
    }
    return "${data["rtmp_url"]}/${HtmlUnescape().convert(data["rtmp_live"].toString())}";
  }

  /// 签名参数缓存：homeH5Enc 拉脚本+签名不依赖房间详情，
  /// 进房时可与 getRoomDetail 并行预热，首帧少等一个 RTT。
  /// 签名含时间戳，超过 TTL 视为过期重新签
  final Map<String, ({String args, DateTime time})> _freshArgsCache = {};
  static const _freshArgsTtl = Duration(seconds: 60);

  /// 容量上限：防止长时间浏览大量房间后无界增长
  static const _freshArgsCacheMax = 50;

  /// 预热播放签名：进房时与 getRoomDetail 并行发起
  Future<void> warmPlayArgs(String roomId) async {
    if (_preferV1) {
      return;
    }
    try {
      await _getFreshPlayArgs(roomId, fallback: "");
    } catch (_) {}
  }

  /// 每次取流前重新拉取加密脚本并签名，返回带新时间戳的播放参数。
  /// 失败时回退到 [fallback]（getRoomDetail 时缓存的签名）。
  Future<String> _getFreshPlayArgs(String roomId, {Object? fallback}) async {
    var cached = _freshArgsCache[roomId];
    if (cached != null &&
        DateTime.now().difference(cached.time) < _freshArgsTtl) {
      return cached.args;
    }
    try {
      var jsEncResult = await HttpClient.instance.getText(
        "https://www.douyu.com/swf_api/homeH5Enc?rids=$roomId",
        queryParameters: {},
        header: {
          ..._requestHeaders,
          'referer': 'https://www.douyu.com/$roomId',
        },
      );
      var decoded = json.decode(jsEncResult);
      var payload = decoded is Map ? decoded["data"] : null;
      var script = payload is Map ? payload["room$roomId"] : null;
      if (script is String && script.isNotEmpty) {
        var signed = DouyuSign.getSign(script, roomId, _deviceDid);
        if (signed.isNotEmpty) {
          // 按插入序淘汰最旧条目
          if (_freshArgsCache.length >= _freshArgsCacheMax) {
            _freshArgsCache.remove(_freshArgsCache.keys.first);
          }
          _freshArgsCache[roomId] = (args: signed, time: DateTime.now());
          return signed;
        }
      }
    } catch (_) {}
    var value = fallback?.toString() ?? "";
    if (value.isEmpty) {
      throw CoreError("斗鱼播放签名刷新失败");
    }
    return value;
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/weblist/apinc/allpage/6/$page",
      queryParameters: {},
    );

    var items = <LiveRoomItem>[];
    for (var item in result['data']['rl']) {
      if (item["type"] != 1) {
        continue;
      }
      var roomItem = LiveRoomItem(
        cover: item['rs16'].toString(),
        online: item['ol'],
        roomId: item['rid'].toString(),
        title: item['rn'].toString(),
        userName: item['nn'].toString(),
      );
      items.add(roomItem);
    }
    var hasMore = page < result['data']['pgcnt'];
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    // 三个请求互不依赖，并行发起：
    // 房间详情 / 开播时间(h5room) / 播放签名(homeH5Enc+JS签名)
    // 签名与 warmPlayArgs 共用 _freshArgsCache：进房预热完成后
    // 这里直接命中缓存，不再重复拉脚本签名；
    // h5room 只提供开播时间，失败不阻塞详情
    final roomInfoFuture = _getRoomInfo(roomId);
    final h5RoomInfoFuture = HttpClient.instance
        .getJson(
          "https://www.douyu.com/swf_api/h5room/$roomId",
          queryParameters: {},
          header: {
            ..._requestHeaders,
            'referer': 'https://www.douyu.com/$roomId'
          },
        )
        .then((value) => value is Map ? value : null)
        .onError((_, __) => null);
    // V1 模式下画质与取流均不使用 V0 签名参数，跳过整条签名链路
    final playArgsFuture = _preferV1
        ? Future<String>.value("")
        : _getFreshPlayArgs(roomId, fallback: "");

    Map roomInfo = await roomInfoFuture;
    Map? h5RoomInfo = await h5RoomInfoFuture;
    String playArgs = await playArgsFuture;
    String? showTime = h5RoomInfo?["data"]?["show_time"]?.toString();

    if (showTime != null && showTime.isNotEmpty) {
      try {
        int startTimeStamp = int.parse(showTime);
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        print('斗鱼直播间 $roomId 开播时长: $formattedDuration');
      } catch (e) {
        print('计算开播时长出错: $e');
      }
    }

    return LiveRoomDetail(
      cover: roomInfo["room_pic"].toString(),
      online: int.tryParse(roomInfo["room_biz_all"]["hot"].toString()) ?? 0,
      roomId: roomInfo["room_id"].toString(),
      title: roomInfo["room_name"].toString(),
      userName: roomInfo["owner_name"].toString(),
      userAvatar: roomInfo["owner_avatar"].toString(),
      introduction: roomInfo["show_details"].toString(),
      notice: "",
      status: roomInfo["show_status"] == 1 && roomInfo["videoLoop"] != 1,
      danmakuData: roomInfo["room_id"].toString(),
      data: playArgs,
      url: "https://www.douyu.com/$roomId",
      isRecord: roomInfo["videoLoop"] == 1,
      showTime: showTime,
    );
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    var did = generateRandomString(32);
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchShow",
      queryParameters: {"kw": keyword, "page": page, "pageSize": 20},
      header: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.51',
        'referer': 'https://www.douyu.com/search/',
        'Cookie': 'dy_did=$did;acf_did=$did',
      },
    );
    if (result['error'] != 0) {
      throw Exception(result['msg']);
    }
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["relateShow"]) {
      var roomItem = LiveRoomItem(
        roomId: item["rid"].toString(),
        title: item["roomName"].toString(),
        cover: item["roomSrc"].toString(),
        userName: item["nickName"].toString(),
        online: parseHotNum(item["hot"].toString()),
      );
      items.add(roomItem);
    }
    var hasMore = result["data"]["relateShow"].isNotEmpty;
    return LiveSearchRoomResult(hasMore: hasMore, items: items);
  }

  Future<Map> _getRoomInfo(String roomId) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/betard/$roomId",
      queryParameters: {},
      header: {..._requestHeaders, 'referer': 'https://www.douyu.com/$roomId'},
    );
    Map roomInfo;
    if (result is String) {
      roomInfo = json.decode(result)["room"];
    } else {
      roomInfo = result["room"];
    }
    return roomInfo;
  }

  //生成指定长度的16进制随机字符串
  static String generateRandomString(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(16));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item.toRadixString(16));
    }
    return stringBuffer.toString();
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    var did = generateRandomString(32);
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchUser",
      queryParameters: {
        "kw": keyword,
        "page": page,
        "pageSize": 20,
        "filterType": 1,
      },
      header: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.51',
        'referer': 'https://www.douyu.com/search/',
        'Cookie': 'dy_did=$did;acf_did=$did',
      },
    );

    var items = <LiveAnchorItem>[];
    for (var item in result["data"]["relateUser"]) {
      var liveStatus =
          (int.tryParse(item["anchorInfo"]["isLive"].toString()) ?? 0) == 1;
      var roomType =
          (int.tryParse(item["anchorInfo"]["roomType"].toString()) ?? 0);
      var roomItem = LiveAnchorItem(
        roomId: item["anchorInfo"]["rid"].toString(),
        avatar: item["anchorInfo"]["avatar"].toString(),
        userName: item["anchorInfo"]["nickName"].toString(),
        liveStatus: liveStatus && roomType == 0,
      );
      items.add(roomItem);
    }
    var hasMore = result["data"]["relateUser"].isNotEmpty;
    return LiveSearchAnchorResult(hasMore: hasMore, items: items);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var roomInfo = await _getRoomInfo(roomId);
    return roomInfo["show_status"] == 1 && roomInfo["videoLoop"] != 1;
  }

  int parseHotNum(String hn) {
    try {
      var num = double.parse(hn.replaceAll("万", ""));
      if (hn.contains("万")) {
        num *= 10000;
      }
      return num.round();
    } catch (_) {
      return -999;
    }
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    //尚不支持
    return Future.value([]);
  }
}

class DouyuPlayData {
  final int rate;
  final List<String> cdns;
  DouyuPlayData(this.rate, this.cdns);
}
