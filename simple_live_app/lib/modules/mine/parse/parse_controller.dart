import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_shared/app/constant.dart';
import 'package:simple_live_shared/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/routes/app_navigation.dart';

/// 链接解析结果：[site] 平台下的 [roomId]
class ParsedRoom {
  const ParsedRoom(this.site, this.roomId);

  final Site site;
  final String roomId;
}

class ParseController extends GetxController {
  final TextEditingController roomJumpToController = TextEditingController();
  final TextEditingController getUrlController = TextEditingController();

  /// 只用于跟随短链 302 的请求：validateStatus 放行使 302 直接返回响应而非抛异常
  static final Dio _locationDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      followRedirects: false,
      validateStatus: (_) => true,
    ),
  );

  void jumpToRoom(String e) async {
    if (e.isEmpty) {
      SmartDialog.showToast("链接不能为空");
      return;
    }
    // 隐藏键盘
    FocusManager.instance.primaryFocus?.unfocus();

    SmartDialog.showLoading(msg: "解析中");
    var result = await parse(e);
    SmartDialog.dismiss(status: SmartStatus.loading);
    if (result == null) {
      SmartDialog.showToast("无法解析此链接");
      return;
    }
    AppNavigator.toLiveRoomDetail(site: result.site, roomId: result.roomId);
  }

  void getPlayUrl(String e) async {
    if (e.isEmpty) {
      SmartDialog.showToast("链接不能为空");
      return;
    }
    var result = await parse(e);
    if (result == null) {
      SmartDialog.showToast("无法解析此链接");
      return;
    }
    Site site = result.site;
    try {
      SmartDialog.showLoading(msg: "");
      var detail = await site.liveSite.getRoomDetail(
        roomId: result.roomId,
        withDanmaku: false,
      );
      var qualites = await site.liveSite.getPlayQualites(detail: detail);
      SmartDialog.dismiss(status: SmartStatus.loading);
      if (qualites.isEmpty) {
        SmartDialog.showToast("读取直链失败,无法读取清晰度");

        return;
      }
      var quality = await Get.dialog(SimpleDialog(
        title: const Text("选择清晰度"),
        children: qualites
            .map(
              (e) => ListTile(
                title: Text(
                  e.quality,
                  textAlign: TextAlign.center,
                ),
                onTap: () {
                  Get.back(result: e);
                },
              ),
            )
            .toList(),
      ));
      if (quality == null) {
        return;
      }
      SmartDialog.showLoading(msg: "");
      var playUrl =
          await site.liveSite.getPlayUrls(detail: detail, quality: quality);
      SmartDialog.dismiss(status: SmartStatus.loading);
      await Get.dialog(SimpleDialog(
        title: const Text("选择线路"),
        children: playUrl.urls
            .map(
              (e) => ListTile(
                title: Text(
                  "线路${playUrl.urls.indexOf(e) + 1}",
                ),
                subtitle: Text(
                  e,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: e));
                  Get.back();
                  SmartDialog.showToast("已复制直链");
                },
              ),
            )
            .toList(),
      ));
    } catch (e) {
      SmartDialog.showToast("读取直链失败");
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 解析直播间链接，短链会跟随 302 重定向；
  /// 无法识别的平台或缺少房间号时返回 null
  Future<ParsedRoom?> parse(String url) async {
    if (url.contains("bilibili.com")) {
      var regExp = RegExp(r"bilibili\.com/([\d|\w]+)");
      var id = regExp.firstMatch(url)?.group(1) ?? "";
      return _room(Constant.kBiliBili, id);
    }

    if (url.contains("b23.tv")) {
      var btvReg = RegExp(r"https?:\/\/b23.tv\/[0-9a-z-A-Z]+");
      var u = btvReg.firstMatch(url)?.group(0) ?? "";
      var location = await getLocation(u);

      return await parse(location);
    }

    if (url.contains("douyu.com")) {
      var regExp = RegExp(r"douyu\.com/([\d|\w]+)");
      // 适配 topic_url
      if (url.contains("topic")) {
        regExp = RegExp(r"[?&]rid=([\d]+)");
      }
      var id = regExp.firstMatch(url)?.group(1) ?? "";

      return _room(Constant.kDouyu, id);
    }
    if (url.contains("huya.com")) {
      var regExp = RegExp(r"huya\.com/([\d|\w]+)");
      var id = regExp.firstMatch(url)?.group(1) ?? "";

      return _room(Constant.kHuya, id);
    }
    if (url.contains("live.douyin.com")) {
      var regExp = RegExp(r"live\.douyin\.com/([\d|\w]+)");
      var id = regExp.firstMatch(url)?.group(1) ?? "";

      return _room(Constant.kDouyin, id);
    }
    if (url.contains("webcast.amemv.com")) {
      var regExp = RegExp(r"reflow/(\d+)");
      var id = regExp.firstMatch(url)?.group(1) ?? "";
      return _room(Constant.kDouyin, id);
    }
    if (url.contains("v.douyin.com")) {
      var regExp = RegExp(r"http.?://v.douyin.com/[\d\w]+/");
      var u = regExp.firstMatch(url)?.group(0) ?? "";
      var location = await getLocation(u);
      return await parse(location);
    }

    return null;
  }

  ParsedRoom? _room(String siteId, String roomId) {
    final site = Sites.allSites[siteId];
    if (site == null || roomId.isEmpty) {
      return null;
    }
    return ParsedRoom(site, roomId);
  }

  /// 获取短链的 302 跳转地址，失败或非重定向返回空串
  Future<String> getLocation(String url) async {
    if (url.isEmpty) return "";
    try {
      final response = await _locationDio.get(url);
      final code = response.statusCode ?? 0;
      if (code == 301 || code == 302 || code == 307 || code == 308) {
        var location = response.headers.value("location") ?? "";
        // Location 可能是相对路径，基于原地址解析为绝对地址
        return location.isEmpty ? "" : Uri.parse(url).resolve(location).toString();
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return "";
  }

  @override
  void onClose() {
    roomJumpToController.dispose();
    getUrlController.dispose();
    super.onClose();
  }
}
