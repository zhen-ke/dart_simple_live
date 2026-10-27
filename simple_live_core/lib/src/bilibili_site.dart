import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/src/common/convert_helper.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/bilibili_danmaku.dart';
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

class BiliBiliSite implements LiveSite {
  @override
  String id = "bilibili";

  @override
  String name = "哔哩哔哩直播";

  String _cookie = "";
  String get cookie => _cookie;

  /// 账号变更后，与身份相关的缓存全部作废：
  /// WBI 签名键与 accessId 均按旧身份获取，必须重新拉取
  set cookie(String value) {
    if (_cookie != value) {
      _cookie = value;
      _invalidateWbiKeys();
      accessId = '';
    }
  }

  int userId = 0;

  @override
  LiveDanmaku getDanmaku() => BiliBiliDanmaku();

  static const String kDefaultUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0";
  static const String kDefaultReferer = "https://live.bilibili.com/";

  String buvid3 = "";
  String buvid4 = "";
  String accessId = "";
  Future<Map<String, String>> getHeader() async {
    if (buvid3.isEmpty) {
      var buvidInfo = await getBuvid();
      buvid3 = buvidInfo["b_3"] ?? "";
      buvid4 = buvidInfo["b_4"] ?? "";
    }
    return cookie.isEmpty
        ? {
            "user-agent": kDefaultUserAgent,
            "referer": kDefaultReferer,
            "cookie": 'buvid3=$buvid3;buvid4=$buvid4;',
          }
        : {
            "cookie": cookie.contains("buvid3")
                ? cookie
                : "$cookie;buvid3=$buvid3;buvid4=$buvid4;",
            "user-agent": kDefaultUserAgent,
            "referer": kDefaultReferer,
          };
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/room/v1/Area/getList",
      queryParameters: {
        "need_entrance": 1,
        "parent_id": 0,
      },
      header: await getHeader(),
    );
    for (var item in result["data"]) {
      List<LiveSubCategory> subs = [];
      for (var subItem in item["list"]) {
        var subCategory = LiveSubCategory(
          id: subItem["id"].toString(),
          name: asT<String?>(subItem["name"]) ?? "",
          parentId: asT<String?>(subItem["parent_id"]) ?? "",
          pic: "${asT<String?>(subItem["pic"]) ?? ""}@100w.png",
        );
        subs.add(subCategory);
      }
      var category = LiveCategory(
        children: subs,
        id: item["id"].toString(),
        name: asT<String?>(item["name"]) ?? "",
      );
      categories.add(category);
    }
    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(LiveSubCategory category,
      {int page = 1}) async {
    const baseUrl =
        "https://api.live.bilibili.com/xlive/web-interface/v1/second/getList";

    var url =
        "$baseUrl?platform=web&parent_area_id=${category.parentId}&area_id=${category.id}&sort_type=&page=$page&w_webid=${await getAccessId()}";

    var result = await _getWbiSignedJson(url);

    var hasMore = result["data"]["has_more"] == 1;
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["list"]) {
      var roomItem = LiveRoomItem(
        roomId: item["roomid"].toString(),
        title: item["title"].toString(),
        cover: "${item["cover"]}@400w.jpg",
        userName: item["uname"].toString(),
        online: int.tryParse(item["online"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  static const String _playInfoUrl =
      "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo";

  /// 进房时 getPlayQualites 与 getPlayUrls 打的是同一个 getRoomPlayInfo，
  /// 参数只差 qn。首次响应按房间缓存，qn 命中就直接复用，省掉进房时
  /// 第二次几百 KB 的大响应往返；qn 不同或超过 TTL 才重新请求。
  static const Duration _playInfoCacheTtl = Duration(seconds: 30);
  String? _playInfoRoomId;
  int? _playInfoQn;
  DateTime? _playInfoAt;
  dynamic _playInfoData;

  /// 两处请求参数必须一致，缓存下来的响应才能直接当取流响应用：
  /// 只要 avc（codec 0）的 flv/fmp4（format 0,2）
  Future<dynamic> _requestPlayInfo(String roomId, {int? qn}) async {
    return HttpClient.instance.getJson(
      _playInfoUrl,
      queryParameters: {
        "room_id": roomId,
        "protocol": "0,1",
        "format": "0,2",
        "codec": "0",
        "platform": "web",
        if (qn != null) "qn": "$qn",
      },
      header: await getHeader(),
    );
  }

  dynamic _playurlNode(dynamic result) {
    if (result is! Map) return null;
    var data = result["data"];
    if (data is! Map) return null;
    var playurlInfo = data["playurl_info"];
    if (playurlInfo is! Map) return null;
    var playurl = playurlInfo["playurl"];
    return playurl is Map ? playurl : null;
  }

  /// 拍平 stream/format/codec 三层，清晰度和取流都从这里取
  Iterable<Map> _codecs(dynamic result) sync* {
    var playurl = _playurlNode(result);
    if (playurl == null) return;
    var streams = playurl["stream"];
    if (streams is! List) return;
    for (var stream in streams) {
      if (stream is! Map) continue;
      var formats = stream["format"];
      if (formats is! List) continue;
      for (var format in formats) {
        if (format is! Map) continue;
        var codecs = format["codec"];
        if (codecs is! List) continue;
        for (var codec in codecs) {
          if (codec is Map) yield codec;
        }
      }
    }
  }

  /// 响应里当前实际下发的清晰度，用于判断缓存能否直接复用
  int? _readCurrentQn(dynamic result) {
    for (var codec in _codecs(result)) {
      var qn = int.tryParse("${codec["current_qn"]}");
      if (qn != null) return qn;
    }
    return null;
  }

  List<int> _readAcceptQn(dynamic result) {
    for (var codec in _codecs(result)) {
      var acceptQn = codec["accept_qn"];
      if (acceptQn is List) {
        return acceptQn
            .map((e) => int.tryParse("$e") ?? 0)
            .where((e) => e > 0)
            .toList();
      }
    }
    return const [];
  }

  void _rememberPlayInfo(String roomId, dynamic result) {
    if (result is! Map) return;
    _playInfoRoomId = roomId;
    _playInfoQn = _readCurrentQn(result);
    _playInfoAt = DateTime.now();
    _playInfoData = result;
  }

  dynamic _cachedPlayInfo(String roomId, int? qn) {
    var data = _playInfoData;
    var at = _playInfoAt;
    if (data == null || at == null) return null;
    if (DateTime.now().difference(at) > _playInfoCacheTtl) {
      // 过期即释放，不把几百 KB 的响应一直挂在站点实例上
      _playInfoData = null;
      _playInfoQn = null;
      _playInfoAt = null;
      return null;
    }
    if (_playInfoRoomId != roomId) return null;
    if (qn == null || _playInfoQn != qn) return null;
    return data;
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
      {required LiveRoomDetail detail}) async {
    List<LivePlayQuality> qualities = [];
    var result = await _requestPlayInfo(detail.roomId);
    _rememberPlayInfo(detail.roomId, result);

    var qualitiesMap = <int, String>{};
    var playurl = _playurlNode(result);
    var descriptions = playurl?["g_qn_desc"];
    if (descriptions is List) {
      for (var item in descriptions) {
        if (item is! Map) continue;
        qualitiesMap[int.tryParse(item["qn"].toString()) ?? 0] =
            item["desc"].toString();
      }
    }

    for (var qn in _readAcceptQn(result)) {
      qualities.add(
        LivePlayQuality(
          quality: qualitiesMap[qn] ?? "未知清晰度",
          data: qn,
        ),
      );
    }
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls(
      {required LiveRoomDetail detail,
      required LivePlayQuality quality}) async {
    List<String> urls = [];
    var qn = int.tryParse("${quality.data}");
    var result = _cachedPlayInfo(detail.roomId, qn);
    if (result == null) {
      result = await _requestPlayInfo(detail.roomId, qn: qn);
      // 换清晰度后重新请求的响应同样缓存，来回切换不必重复拉流
      _rememberPlayInfo(detail.roomId, result);
    }

    for (var codec in _codecs(result)) {
      var urlList = codec["url_info"];
      if (urlList is! List) continue;
      var baseUrl = codec["base_url"].toString();
      for (var urlItem in urlList) {
        if (urlItem is! Map) continue;
        urls.add(
          "${urlItem["host"]}$baseUrl${urlItem["extra"]}",
        );
      }
    }
    // 对链接进行排序，包含mcdn的在后
    urls.sort((a, b) {
      if (a.contains("mcdn")) {
        return 1;
      } else {
        return -1;
      }
    });
    return LivePlayUrl(
      urls: urls,
      headers: {
        "referer": "https://live.bilibili.com",
        "user-agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36 Edg/115.0.1901.188"
      },
    );
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    const baseUrl =
        "https://api.live.bilibili.com/xlive/web-interface/v1/second/getListByArea";
    var url = "$baseUrl?platform=web&sort=online&page_size=30&page=$page";

    var result = await _getWbiSignedJson(url);

    var hasMore = (result["data"]["list"] as List).isNotEmpty;
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["list"]) {
      var roomItem = LiveRoomItem(
        roomId: item["roomid"].toString(),
        title: item["title"].toString(),
        cover: "${item["cover"]}@400w.jpg",
        userName: item["uname"].toString(),
        online: int.tryParse(item["online"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({
    required String roomId,
    bool withDanmaku = true,
  }) async {
    var roomInfo = await getRoomInfo(roomId: roomId);
    var realRoomId = roomInfo["room_info"]["room_id"].toString();

    //var buvid = await getBuvid();
    // 从 roomInfo 中提取 live_start_time
    String? liveStartTime =
        roomInfo["room_info"]?["live_start_time"]?.toString();

    return LiveRoomDetail(
      roomId: realRoomId,
      title: roomInfo["room_info"]["title"].toString(),
      cover: roomInfo["room_info"]["cover"].toString(),
      userName: roomInfo["anchor_info"]["base_info"]["uname"].toString(),
      userAvatar: "${roomInfo["anchor_info"]["base_info"]["face"]}@100w.jpg",
      online: asT<int?>(roomInfo["room_info"]["online"]) ?? 0,
      status: (asT<int?>(roomInfo["room_info"]["live_status"]) ?? 0) == 1,
      url: "https://live.bilibili.com/$roomId",
      introduction: roomInfo["room_info"]["description"].toString(),
      notice: "",
      // 弹幕参数按需解析：详情先返回，视频取流不等弹幕接口；
      // 只做关注状态/开播时间等轻量查询时完全不发这个请求。
      danmakuData: withDanmaku ? _prepareDanmakuArgs(realRoomId) : null,
      showTime: liveStartTime, // 将 liveStartTime 赋值给 showTime 字段
    );
  }

  /// 弹幕参数解析：getRoomDetail 返回后立即在后台发起，
  /// getDanmuInfo 的耗时与失败不再阻塞房间详情返回。
  ///
  /// 失败时返回 null 而不是把错误留在无人监听的 Future 里：
  /// 关注列表、状态核实等调用方根本不会 await 这个值。
  Future<BiliBiliDanmakuArgs?> _prepareDanmakuArgs(String realRoomId) async {
    try {
      const danmuInfoBaseUrl =
          "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo";
      var danmuInfoUrl = "$danmuInfoBaseUrl?id=$realRoomId";
      var roomDanmakuResult = await _getWbiSignedJson(danmuInfoUrl);
      List<String> serverHosts =
          (roomDanmakuResult["data"]["host_list"] as List)
              .map<String>((e) => e["host"].toString())
              .toList();
      return BiliBiliDanmakuArgs(
        roomId: int.tryParse(realRoomId) ?? 0,
        uid: userId,
        token: roomDanmakuResult["data"]["token"].toString(),
        serverHost: serverHosts.isNotEmpty
            ? serverHosts.first
            : "broadcastlv.chat.bilibili.com",
        buvid: buvid3,
        cookie: cookie,
      );
    } catch (e, stackTrace) {
      CoreLog.e("获取哔哩哔哩弹幕参数失败：$e", stackTrace);
      return null;
    }
  }

  Future<Map<String, dynamic>> getRoomInfo({required String roomId}) async {
    var url =
        "https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom?room_id=$roomId";
    var result = await _getWbiSignedJson(url);
    return result["data"];
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword,
      {int page = 1}) async {
    var result = await HttpClient.instance.getJson(
      "https://api.bilibili.com/x/web-interface/search/type?context=&search_type=live&cover_type=user_cover",
      queryParameters: {
        "order": "",
        "keyword": keyword,
        "category_id": "",
        "__refresh__": "",
        "_extra": "",
        "highlight": 0,
        "single_column": 0,
        "page": page
      },
      header: await getHeader(),
    );

    var items = <LiveRoomItem>[];
    for (var item in result["data"]["result"]["live_room"] ?? []) {
      var title = item["title"].toString();
      //移除title中的<em></em>标签
      title = title.replaceAll(RegExp(r"<.*?em.*?>"), "");
      var roomItem = LiveRoomItem(
        roomId: item["roomid"].toString(),
        title: title,
        cover: "https:${item["cover"]}@400w.jpg",
        userName: item["uname"].toString(),
        online: int.tryParse(item["online"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveSearchRoomResult(hasMore: items.length >= 40, items: items);
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword,
      {int page = 1}) async {
    var result = await HttpClient.instance.getJson(
      "https://api.bilibili.com/x/web-interface/search/type?context=&search_type=live_user&cover_type=user_cover",
      queryParameters: {
        "order": "",
        "keyword": keyword,
        "category_id": "",
        "__refresh__": "",
        "_extra": "",
        "highlight": 0,
        "single_column": 0,
        "page": page
      },
      header: await getHeader(),
    );

    var items = <LiveAnchorItem>[];
    for (var item in result["data"]["result"] ?? []) {
      var uname = item["uname"].toString();
      //移除title中的<em></em>标签
      uname = uname.replaceAll(RegExp(r"<.*?em.*?>"), "");
      var anchorItem = LiveAnchorItem(
        roomId: item["roomid"].toString(),
        avatar: "https:${item["uface"]}@400w.jpg",
        userName: uname,
        liveStatus: item["is_live"],
      );
      items.add(anchorItem);
    }
    return LiveSearchAnchorResult(hasMore: items.length >= 40, items: items);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/room/v1/Room/get_info",
      queryParameters: {
        "room_id": roomId,
      },
      header: await getHeader(),
    );
    return (asT<int?>(result["data"]["live_status"]) ?? 0) == 1;
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage(
      {required String roomId}) async {
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/av/v1/SuperChat/getMessageList",
      queryParameters: {
        "room_id": roomId,
      },
      header: await getHeader(),
    );
    List<LiveSuperChatMessage> ls = [];
    for (var item in result["data"]?["list"] ?? []) {
      var message = LiveSuperChatMessage(
        backgroundBottomColor: item["background_bottom_color"].toString(),
        backgroundColor: item["background_color"].toString(),
        endTime: DateTime.fromMillisecondsSinceEpoch(
          item["end_time"] * 1000,
        ),
        face: "${item["user_info"]["face"]}@200w.jpg",
        message: item["message"].toString(),
        price: item["price"],
        startTime: DateTime.fromMillisecondsSinceEpoch(
          item["start_time"] * 1000,
        ),
        userName: item["user_info"]["uname"].toString(),
      );
      ls.add(message);
    }
    return ls;
  }

  /// 获取 buvid3 和 buvid4
  /// 返回buvid3和buvid4
  /// ``` json
  /// {
  ///   "b_3": "buvid3",
  ///   "b_4": "buvid4",
  /// }
  /// ```
  Future<Map> getBuvid() async {
    try {
      if (cookie.contains("buvid3")) {
        return {
          "b_3": RegExp(r"buvid3=(.*?);").firstMatch(cookie)?.group(1) ?? "",
          "b_4": RegExp(r"buvid4=(.*?);").firstMatch(cookie)?.group(1) ?? "",
        };
      }

      var result = await HttpClient.instance.getJson(
        "https://api.bilibili.com/x/frontend/finger/spi",
        queryParameters: {},
        header: {
          "user-agent": kDefaultUserAgent,
          "referer": kDefaultReferer,
          "cookie": cookie,
        },
      );
      return result["data"];
    } catch (e) {
      return {
        "b_3": "",
        "b_4": "",
      };
    }
  }

  static String kImgKey = '';
  static String kSubKey = '';

  /// WBI 密钥会轮换：缓存 12 小时后强制重新拉取
  static const _wbiKeysTtl = Duration(hours: 12);
  static DateTime? _wbiKeysFetchedAt;

  /// 并发签名共享同一个密钥拉取任务，避免重复请求 nav 接口
  static Future<(String, String)>? _wbiKeysTask;
  static const List<int> mixinKeyEncTab = [
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
    37,
    48,
    7,
    16,
    24,
    55,
    40,
    61,
    26,
    17,
    0,
    1,
    60,
    51,
    30,
    4,
    22,
    25,
    54,
    21,
    56,
    59,
    6,
    63,
    57,
    62,
    11,
    36,
    20,
    34,
    44,
    52
  ];
  /// WBI 签名请求统一入口：密钥轮换或风控拒绝（-352/-412）时
  /// 作废本地缓存键并重签重试一次，防止密钥过期导致整轮失败
  Future<dynamic> _getWbiSignedJson(String url) async {
    var result = await _requestWbiSigned(url);
    if (_isWbiSignRejected(result)) {
      _invalidateWbiKeys();
      result = await _requestWbiSigned(url);
    }
    return result;
  }

  Future<dynamic> _requestWbiSigned(String url) async {
    var uri = Uri.parse(url);
    var baseUrl = "${uri.scheme}://${uri.host}${uri.path}";
    var queryParams = await getWbiSign(url);
    return HttpClient.instance.getJson(
      baseUrl,
      queryParameters: queryParams,
      header: await getHeader(),
    );
  }

  /// -352 风控校验失败 / -412 请求被拦截：均为 WBI 签名不被接受的响应
  bool _isWbiSignRejected(dynamic result) =>
      result is Map && (result["code"] == -352 || result["code"] == -412);

  /// 作废本地 WBI 密钥：签名被拒或账号变更时调用
  void _invalidateWbiKeys() {
    kImgKey = '';
    kSubKey = '';
    _wbiKeysFetchedAt = null;
  }

  Future<(String, String)> getWbiKeys() {
    if (kImgKey.isNotEmpty &&
        kSubKey.isNotEmpty &&
        _wbiKeysFetchedAt != null &&
        DateTime.now().difference(_wbiKeysFetchedAt!) < _wbiKeysTtl) {
      return Future.value((kImgKey, kSubKey));
    }
    return _wbiKeysTask ??=
        _fetchWbiKeys().whenComplete(() => _wbiKeysTask = null);
  }

  Future<(String, String)> _fetchWbiKeys() async {
    // 获取最新的 img_key 和 sub_key
    var resp = await HttpClient.instance.getJson(
      'https://api.bilibili.com/x/web-interface/nav',
      header: await getHeader(),
    );

    var imgUrl = resp["data"]["wbi_img"]["img_url"].toString();
    var subUrl = resp["data"]["wbi_img"]["sub_url"].toString();
    var imgKey = imgUrl.substring(imgUrl.lastIndexOf('/') + 1).split('.').first;
    var subKey = subUrl.substring(subUrl.lastIndexOf('/') + 1).split('.').first;

    kImgKey = imgKey;
    kSubKey = subKey;
    _wbiKeysFetchedAt = DateTime.now();

    return (imgKey, subKey);
  }

  String getMixinKey(String origin) {
    // 对 imgKey 和 subKey 进行字符顺序打乱编码
    return mixinKeyEncTab.fold("", (s, i) => s + origin[i]).substring(0, 32);
  }

  Future<Map<String, String>> getWbiSign(String url) async {
    var (imgKey, subKey) = await getWbiKeys();

    // 为请求参数进行 wbi 签名
    var mixinKey = getMixinKey(imgKey + subKey);
    var currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    var queryParams = Map<String, String>.from(Uri.parse(url).queryParameters);

    queryParams["wts"] = currentTime.toString(); // 添加 wts 字段

    //按照 key 重排参数
    Map<String, String> map = {};
    var sortedKeys = queryParams.keys.toList()..sort();
    for (var key in sortedKeys) {
      var value = queryParams[key]!;
      // 过滤 value 中的 "!'()*" 字符
      map[key] = value
          .toString()
          .split('')
          .where((c) => "!'()*".contains(c) == false)
          .join('');
    }

    var query = map.keys
        .map((key) => "$key=${Uri.encodeQueryComponent(map[key]!)}")
        .join("&");
    var wbiSign = md5.convert(utf8.encode("$query$mixinKey")).toString();
    queryParams["w_rid"] = wbiSign;
    return queryParams;
  }

  Future<String> getAccessId() async {
    if (accessId.isNotEmpty) {
      return accessId;
    }

    // 获取 access_id
    var resp = await HttpClient.instance.getText(
      "https://live.bilibili.com/lol",
      queryParameters: {},
      header: await getHeader(),
    );
    var id = RegExp(r'"access_id":"(.*?)"')
        .firstMatch(resp)
        ?.group(1)
        ?.replaceAll("\\", "");
    accessId = id ?? "";
    return accessId;
  }
}
