import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:udp/udp.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

class SyncService extends GetxService {
  static SyncService get instance => Get.find<SyncService>();

  UDP? udp;
  RxList<SyncClinet> scanClients = <SyncClinet>[].obs;
  static const int udpPort = 23235;
  static const int httpPort = 23234;
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  NetworkInfo networkInfo = NetworkInfo();
  HttpServer? server;
  var ipAddress = "".obs;
  var httpRunning = false.obs;
  var httpErrorMsg = "".obs;

  var deviceId = "";

  @override
  void onInit() {
    Log.d('TVService init');
    deviceId = (const Uuid().v4()).split('-').first;
    // HTTP 服务改为进入同步页时按需启动，不再应用启动即监听；
    // UDP 常驻监听，但仅在 httpRunning 时才会回应发现广播
    listenUDP();
    super.onInit();
  }

  /// 监听其他端UDP广播的回复
  void listenUDP() async {
    udp = await UDP.bind(Endpoint.any(port: const Port(udpPort)));
    udp!.asStream().listen(listenUdp);
  }

  void listenUdp(Datagram? datagram) {
    var str = String.fromCharCodes(datagram!.data);
    Log.i("Received: $str from ${datagram.address}:${datagram.port}");
    if (str.startsWith('{') && str.endsWith('}')) {
      var data = json.decode(str);
      //如果是自己的广播，就不处理
      if (data['id'] == deviceId) {
        return;
      }
      //处理Hello的广播
      if (data["type"] == "hello") {
        //如果http服务已经启动，就回复自己的信息
        if (httpRunning.value) {
          sendInfo();
        }
        return;
      }
      // 处理其他端的广播
      // 地址直接从datagram中获取，能收到回复说明地址是可以连通的
      var address = datagram.address.address;
      //检查是否已经存在
      var index =
          scanClients.indexWhere((element) => element.address == address);
      if (index == -1) {
        scanClients.add(
          SyncClinet(
            id: data['id'],
            name: data['name'],
            address: address,
            port: httpPort,
            type: data['type'],
          ),
        );
      }
    }
  }

  /// 发送UDP广播至其他端
  void sendHello() async {
    await udp!.send(
      json.encode({
        "id": deviceId,
        "type": "hello",
      }).codeUnits,
      Endpoint.broadcast(
        port: const Port(udpPort),
      ),
    );
    Log.i("send udp: hello");
  }

  /// UDP广播自身信息
  void sendInfo() async {
    //var ip = await getLocalIP();

    var name = await getDeviceName();

    var data = {
      "id": deviceId,
      "type": Platform.operatingSystem,
      //'version': Utils.packageInfo.version,
      "name": name,
      //"address": ip,
      //"port": httpPort,
    };

    await udp!.send(
      json.encode(data).codeUnits,
      Endpoint.broadcast(
        port: const Port(udpPort),
      ),
    );
    Log.i("send udp info: $data");
  }

  Future<String> getDeviceName() async {
    var name = "SimpleLive-${Platform.operatingSystem}";
    if (Platform.isAndroid) {
      var info = await deviceInfo.androidInfo;
      name = info.model;
    } else if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      name = info.name;
    } else if (Platform.isMacOS) {
      var info = await deviceInfo.macOsInfo;
      name = info.computerName;
    } else if (Platform.isLinux) {
      var info = await deviceInfo.linuxInfo;
      name = info.name;
    } else if (Platform.isWindows) {
      var info = await deviceInfo.windowsInfo;
      name = info.userName;
    }
    return name;
  }

  void refreshClients() {
    scanClients.clear();
    sendHello();
  }

  /// 读取本地IP
  /// - 如果是wifi，直接获取wifi的IP
  /// - 如果是有线，获取所有的IP，找到全部的IP
  Future<String> getLocalIP() async {
    String? ip = "";
    try {
      ip = await networkInfo.getWifiIP();
    } catch (e) {
      Log.logPrint(e);
    }
    try {
      if (ip == null || ip.isEmpty) {
        var interfaces = await NetworkInterface.list();
        var ipList = <String>[];
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            if (addr.type.name == 'IPv4' &&
                !addr.address.startsWith('127') &&
                !addr.isMulticast &&
                !addr.isLoopback) {
              ipList.add(addr.address);
              break;
            }
          }
        }
        ip = ipList.join(';');
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return ip ?? "";
  }

  /// 是否存在正在进行中的服务启动，防止重复绑定端口
  var _serverStarting = false;

  /// 当前是否仍需要HTTP服务（绑定异步完成后的有效性校验）
  var _serverWanted = false;

  /// 进入同步页时启动HTTP服务，幂等
  void startServer() {
    _serverWanted = true;
    if (server != null || _serverStarting) {
      return;
    }
    _serverStarting = true;
    initServer();
  }

  /// 离开同步页时停止HTTP服务：不再对外可见，也不再接收写入
  Future<void> stopServer() async {
    _serverWanted = false;
    httpRunning.value = false;
    var s = server;
    server = null;
    await s?.close(force: true);
  }

  /// 初始化HTTP服务
  void initServer() async {
    try {
      var serverRouter = Router();
      serverRouter.get('/', _helloRequest);
      serverRouter.get('/info', _infoRequest);
      serverRouter.post('/sync/follow', _syncFollowUserReuqest);
      serverRouter.post('/sync/tag', _syncFollowUserTagRequest);
      serverRouter.post('/sync/history', _syncHistoryReuqest);
      serverRouter.post('/sync/blocked_word', _syncBlockedWordReuqest);
      serverRouter.post('/sync/account/bilibili', _syncBiliAccountReuqest);

      var s = await shelf_io.serve(
        serverRouter,
        InternetAddress.anyIPv4,
        httpPort,
      );

      // 等待端口绑定期间用户可能已离开同步页：作废这次启动
      if (!_serverWanted) {
        await s.close(force: true);
        return;
      }
      server = s;

      // Enable content compression
      server!.autoCompress = true;

      httpRunning.value = true;

      var ip = await getLocalIP();
      ipAddress.value = ip;

      Log.d('Serving at http://$ip:${server!.port}');
    } catch (e) {
      httpErrorMsg.value = e.toString();
      Log.logPrint(e);
    } finally {
      _serverStarting = false;
    }
  }

  /// 请求体大小上限：防止异常客户端发送超大载荷耗尽内存
  static const int _maxBodyBytes = 8 * 1024 * 1024;

  /// 带上限地读取请求体
  Future<String> _readLimitedBody(shelf.Request request) async {
    final buffer = BytesBuilder();
    await for (var chunk in request.read()) {
      buffer.add(chunk);
      if (buffer.length > _maxBodyBytes) {
        throw Exception('请求体大小超出限制');
      }
    }
    return utf8.decode(buffer.takeBytes());
  }

  /// 测试服务能否正常访问
  shelf.Response _helloRequest(shelf.Request request) {
    return toJsonResponse({
      'status': true,
      'message': 'http server is running...',
      "version":
          'SimpeLive ${Platform.operatingSystem} v${Utils.packageInfo.version}',
    });
  }

  /// 发送自己的信息
  Future<shelf.Response> _infoRequest(shelf.Request request) async {
    var name = await getDeviceName();
    return toJsonResponse({
      "id": deviceId,
      'type': Platform.operatingSystem,
      'name': name,
      'version': Utils.packageInfo.version,
      'address': ipAddress.value,
      'port': httpPort,
    });
  }

  /// 同步关注用户列表
  Future<shelf.Response> _syncFollowUserReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');

      var body = await _readLimitedBody(request);
      var jsonBody = json.decode(body);
      // 先完整解析再覆盖写入：解析失败不清空本地数据
      final users = <FollowUser>[];
      for (var item in jsonBody) {
        users.add(FollowUser.fromJson(item));
      }
      if (overlay == 1) {
        await DBService.instance.followBox.clear();
      }
      // 批量写入：逐条 await put 每条都会单独落盘
      if (users.isNotEmpty) {
        await DBService.instance.followBox
            .putAll({for (var user in users) user.id: user});
      }

      SmartDialog.showToast('已同步关注用户列表');
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步标签列表
  Future<shelf.Response> _syncFollowUserTagRequest(shelf.Request request) async {
    try {
      var overlay =
      int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');

      var body = await _readLimitedBody(request);
      var jsonBody = json.decode(body);
      // 先完整解析再覆盖写入：解析失败不清空本地数据
      final tags = <FollowUserTag>[];
      for (var item in jsonBody) {
        tags.add(FollowUserTag.fromJson(item));
      }
      if (overlay == 1) {
        await DBService.instance.tagBox.clear();
      }
      if (tags.isNotEmpty) {
        await DBService.instance.tagBox
            .putAll({for (var tag in tags) tag.id: tag});
      }

      SmartDialog.showToast('已同步标签列表');
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步观看记录
  Future<shelf.Response> _syncHistoryReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      var body = await _readLimitedBody(request);
      var jsonBody = json.decode(body);
      // 先完整解析再覆盖写入：解析失败不清空本地数据
      final histories = <History>[];
      for (var item in jsonBody) {
        histories.add(History.fromJson(item));
      }
      if (overlay == 1) {
        await DBService.instance.historyBox.clear();
      }
      // 先在内存里比完新旧，再一次性 putAll
      final merged = <String, History>{};
      for (var history in histories) {
        var old = DBService.instance.historyBox.get(history.id);
        //如果本地的更新时间比较新，就不更新
        if (old is History && old.updateTime.isAfter(history.updateTime)) {
          continue;
        }
        merged[history.id] = history;
      }
      if (merged.isNotEmpty) {
        await DBService.instance.historyBox.putAll(merged);
      }

      SmartDialog.showToast('已同步观看记录');
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步弹幕屏蔽词
  Future<shelf.Response> _syncBlockedWordReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      var body = await _readLimitedBody(request);
      var jsonBody = json.decode(body);
      if (overlay == 1) {
        AppSettingsController.instance.clearShieldList();
      }
      for (var keyword in jsonBody) {
        AppSettingsController.instance.addShieldList(keyword.trim());
      }
      SmartDialog.showToast('已同步弹幕屏蔽词');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步哔哩哔哩账号
  Future<shelf.Response> _syncBiliAccountReuqest(shelf.Request request) async {
    try {
      var body = await _readLimitedBody(request);
      var jsonBody = json.decode(body);
      var cookie = jsonBody['cookie'];
      BiliBiliAccountService.instance.setCookie(cookie);
      BiliBiliAccountService.instance.loadUserInfo();
      SmartDialog.showToast('已同步哔哩哔哩账号');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  shelf.Response toJsonResponse(Map<String, dynamic> data) {
    return shelf.Response.ok(
      json.encode(data),
      headers: {
        'Content-Type': 'application/json',
      },
      encoding: Encoding.getByName('utf-8'),
    );
  }

  @override
  void onClose() {
    Log.d('SyncService close');
    udp?.close();
    server?.close(force: true);
    super.onClose();
  }
}

class SyncClinet {
  final String id;
  final String name;
  final String address;
  final int port;
  final String type;
  SyncClinet({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.type,
  });
}
