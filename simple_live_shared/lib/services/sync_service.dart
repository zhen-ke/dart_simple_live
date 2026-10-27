import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:simple_live_shared/app/constant.dart';
import 'package:simple_live_shared/app/event_bus.dart';
import 'package:simple_live_shared/app/json_isolate.dart';
import 'package:simple_live_shared/app/log.dart';
import 'package:simple_live_shared/models/db/follow_user.dart';
import 'package:simple_live_shared/models/db/follow_user_tag.dart';
import 'package:simple_live_shared/models/db/history.dart';
import 'package:simple_live_shared/services/bilibili_account_service.dart';
import 'package:simple_live_shared/services/db_service.dart';
import 'package:udp/udp.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

class SyncService extends GetxService {
  SyncService({
    required this.platformType,
    required this.defaultDeviceName,
    required this.onAddShieldWord,
    required this.onClearShieldWords,
    required this.confirmDialog,
  });

  /// 对外广播/应答里的平台标识：app 用 Platform.operatingSystem，TV 用 "tv"
  final String platformType;

  /// 设备名兜底值：拿不到真实设备型号时使用（app: `SimpleLive-<os>`，TV: SimpleLive-TV）
  final String defaultDeviceName;

  /// 弹幕屏蔽词的落点：由宿主接自己的设置控制器
  final void Function(String word) onAddShieldWord;
  final Future<void> Function() onClearShieldWords;

  /// 确认弹窗：由宿主接自己的 Utils.showAlertDialog（两端样式一致）
  final Future<bool> Function(
    String content,
    String title,
    String confirm,
    String cancel,
  ) confirmDialog;

  static SyncService get instance => Get.find<SyncService>();

  UDP? udp;
  StreamSubscription<Datagram?>? _udpSubscription;
  Future<void>? _udpStartTask;
  RxList<SyncClinet> scanClients = <SyncClinet>[].obs;
  static const int udpPort = 23235;
  static const int httpPort = 23234;
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  NetworkInfo networkInfo = NetworkInfo();
  HttpServer? server;
  var ipAddress = "".obs;
  var httpRunning = false.obs;
  var httpErrorMsg = "".obs;
  var udpAvailable = false.obs;
  var udpErrorMsg = "".obs;

  var deviceId = "";

  /// 本次服务会话的配对令牌：每次启动 HTTP 服务时轮换。
  /// 写接口必须携带它，避免同网段任意主机直接覆盖本地数据
  /// （旧版本客户端不携带时会被拒绝，需双端一起升级）
  var _syncToken = "";

  /// 写接口鉴权头
  static const String syncTokenHeader = "x-sync-token";

  /// 来源设备名头：客户端写请求必须携带，用于配对确认弹窗展示
  static const String syncClientHeader = "x-sync-client";

  @override
  void onInit() {
    Log.d('SyncService init');
    deviceId = (const Uuid().v4()).split('-').first;
    // HTTP 服务改为进入同步页时按需启动，不再应用启动即监听；
    // UDP 常驻监听，但仅在 httpRunning 时才会回应发现广播。
    // 端口被占用时只降级局域网发现，不能让未捕获异常掀掉整个 App。
    unawaited(listenUDP());
    super.onInit();
  }

  /// 监听其他端UDP广播的回复。
  /// 绑定失败（端口被其他实例/应用占用）时关闭发现能力并记录原因。
  ///
  /// 并发调用共享同一个绑定任务：启动时和进入同步页时可能同时触发，
  /// 不能让后一次 bind 的失败把前一次已成功的 socket 关掉。
  Future<void> listenUDP() {
    if (udp != null) return Future.value();
    final pending = _udpStartTask;
    if (pending != null) return pending;

    final task = _bindUdp();
    _udpStartTask = task;
    unawaited(task.whenComplete(() {
      if (identical(_udpStartTask, task)) {
        _udpStartTask = null;
      }
    }));
    return task;
  }

  Future<void> _bindUdp() async {
    try {
      final socket = await UDP.bind(Endpoint.any(port: const Port(udpPort)));
      udp = socket;
      _udpSubscription = socket.asStream().listen(
        listenUdp,
        onError: (Object error, StackTrace stackTrace) {
          _handleUdpFailure(error, stackTrace);
        },
      );
      udpAvailable.value = true;
      udpErrorMsg.value = "";
    } catch (error, stackTrace) {
      _handleUdpFailure(error, stackTrace);
    }
  }

  void _handleUdpFailure(Object error, StackTrace stackTrace) {
    udpAvailable.value = false;
    udpErrorMsg.value = error.toString();
    Log.e("局域网发现不可用：$error", stackTrace);

    unawaited(_udpSubscription?.cancel());
    _udpSubscription = null;
    final socket = udp;
    udp = null;
    socket?.close();
  }

  void listenUdp(Datagram? datagram) {
    // socket 关闭时 asStream 可能给出 null，空断言会直接把 App 崩掉
    if (datagram == null) return;
    var str = String.fromCharCodes(datagram.data);
    Log.i("Received: $str from ${datagram.address}:${datagram.port}");
    if (str.startsWith('{') && str.endsWith('}')) {
      dynamic data;
      try {
        data = json.decode(str);
      } catch (_) {
        // 同网段任意主机都能往这个端口发广播，非法报文直接忽略
        return;
      }
      if (data is! Map) return;
      //如果是自己的广播，就不处理
      if (data['id'] == deviceId) {
        return;
      }
      //处理Hello的广播
      if (data["type"] == "hello") {
        //如果http服务已经启动，就回复自己的信息
        if (httpRunning.value) {
          unawaited(sendInfo());
        }
        return;
      }
      // 处理其他端的广播
      // 地址直接从datagram中获取，能收到回复说明地址是可以连通的
      var address = datagram.address.address;
      //检查是否已经存在
      var index = scanClients.indexWhere(
        (element) => element.address == address,
      );
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
    } else if (str == 'Who is SimpleLive?') {
      // 旧版客户端的纯文本探测：仍在服务期内则应答
      if (httpRunning.value) {
        unawaited(sendInfo());
      }
    }
  }

  /// 发送UDP广播至其他端
  Future<bool> sendHello() async {
    final socket = udp;
    if (socket == null) return false;
    try {
      await socket.send(
        json.encode({"id": deviceId, "type": "hello"}).codeUnits,
        Endpoint.broadcast(port: const Port(udpPort)),
      );
      Log.i("send udp: hello");
      return true;
    } catch (error, stackTrace) {
      _handleUdpFailure(error, stackTrace);
      return false;
    }
  }

  /// UDP广播自身信息
  Future<bool> sendInfo() async {
    final socket = udp;
    if (socket == null) return false;
    try {
      final name = await getDeviceName();
      final data = {
        "id": deviceId,
        "type": platformType,
        //'version': Log.packageInfo?.version,
        "name": name,
        //"address": ip,
        //"port": httpPort,
      };

      await socket.send(
        json.encode(data).codeUnits,
        Endpoint.broadcast(port: const Port(udpPort)),
      );
      Log.i("send udp info: $data");
      return true;
    } catch (error, stackTrace) {
      _handleUdpFailure(error, stackTrace);
      return false;
    }
  }

  Future<String> getDeviceName() async {
    var name = defaultDeviceName;
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
    unawaited(sendHello());
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
    _syncToken = "";
    // 会话结束：配对记录一并作废，下次启动需重新确认
    _approvedClients.clear();
    _pairApprovalFutures.clear();
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

      // 鉴权挂在路由外层：/sync 下的所有接口（含以后新增的）默认受保护，
      // 不依赖每个 handler 自己记得校验
      final handler = const shelf.Pipeline()
          .addMiddleware(_syncAuthMiddleware())
          .addHandler(serverRouter.call);

      // 每次启动轮换令牌：只有先通过 /info 握手的客户端才能写入
      _syncToken = const Uuid().v4().replaceAll('-', '');

      var s = await shelf_io.serve(handler, InternetAddress.anyIPv4, httpPort);

      // 等待端口绑定期间用户可能已离开同步页：作废这次启动
      if (!_serverWanted) {
        _syncToken = "";
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
          'SimpeLive ${Platform.operatingSystem} v${Log.packageInfo?.version ?? ''}',
    });
  }

  /// 发送自己的信息
  Future<shelf.Response> _infoRequest(shelf.Request request) async {
    var name = await getDeviceName();
    return toJsonResponse({
      "id": deviceId,
      'type': platformType,
      'name': name,
      'version': Log.packageInfo?.version ?? '',
      'address': ipAddress.value,
      'port': httpPort,
      // 配对令牌：客户端拿到后需在每个写请求里带回
      'token': _syncToken,
    });
  }

  /// /sync 写接口的鉴权中间件。
  /// 放在路由外层而不是各 handler 里：新增同步接口默认受保护。
  shelf.Middleware _syncAuthMiddleware() {
    return (shelf.Handler inner) {
      return (shelf.Request request) async {
        final segments = request.url.pathSegments;
        if (segments.isEmpty || segments.first != 'sync') {
          return inner(request);
        }
        final denied = _rejectUnauthorized(request);
        if (denied != null) return denied;
        // 令牌来自公开的 /info，拿到它不构成身份证明：
        // 写入还需要本机用户对来源设备做一次配对确认
        final pairDenied = await _ensurePairApproved(request);
        if (pairDenied != null) return pairDenied;
        return inner(request);
      };
    };
  }

  /// 已通过配对确认的来源设备：本次服务会话内有效
  final Set<String> _approvedClients = {};

  /// 进行中的配对确认：同设备的并发写请求共享同一次弹窗
  final Map<String, Future<bool>> _pairApprovalFutures = {};

  /// 配对确认超时：无响应按拒绝处理，请求方会收到明确错误
  static const Duration _pairApprovalTimeout = Duration(seconds: 30);

  /// 配对确认：客户端在写请求头中带上自己的设备名，
  /// 首次出现的设备需要本机用户弹窗放行。
  /// 返回 null 表示通过，否则返回应直接回给客户端的错误响应。
  Future<shelf.Response?> _ensurePairApproved(shelf.Request request) async {
    final clientName = request.headers[syncClientHeader]?.trim() ?? "";
    if (clientName.isEmpty) {
      return _errorResponse('客户端版本过旧，请升级后重试', status: 403);
    }
    if (_approvedClients.contains(clientName)) {
      return null;
    }
    var pending = _pairApprovalFutures[clientName];
    if (pending == null) {
      final isAccountSync = request.url.pathSegments.contains('account');
      pending = _requestPairApproval(clientName, isAccountSync)
          .whenComplete(() => _pairApprovalFutures.remove(clientName));
      _pairApprovalFutures[clientName] = pending;
    }
    if (!await pending) {
      return _errorResponse('对方未确认本次同步请求', status: 403);
    }
    _approvedClients.add(clientName);
    return null;
  }

  Future<bool> _requestPairApproval(
    String clientName,
    bool isAccountSync,
  ) async {
    try {
      return await confirmDialog(
        isAccountSync
            ? '设备"$clientName"请求同步登录账号（含登录凭据），是否允许？'
            : '设备"$clientName"请求写入本机数据，是否允许？',
        "同步配对确认",
        "允许",
        "拒绝",
      ).timeout(_pairApprovalTimeout);
    } catch (_) {
      // 超时或弹窗失败（如页面已销毁）都按拒绝处理
      return false;
    }
  }

  /// 写接口鉴权：只放行在 /info 握手中拿到本次令牌的客户端。
  /// 返回 null 表示通过，否则返回应直接回给客户端的错误响应。
  shelf.Response? _rejectUnauthorized(shelf.Request request) {
    if (_syncToken.isEmpty) {
      return _errorResponse('同步服务尚未就绪', status: 503);
    }
    if (request.headers[syncTokenHeader] != _syncToken) {
      return _errorResponse('未授权的同步请求', status: 403);
    }
    return null;
  }

  shelf.Response _errorResponse(String message, {int status = 400}) {
    return shelf.Response(
      status,
      body: json.encode({'status': false, 'message': message}),
      headers: {'Content-Type': 'application/json'},
      encoding: Encoding.getByName('utf-8'),
    );
  }

  /// 同步关注用户列表
  Future<shelf.Response> _syncFollowUserReuqest(shelf.Request request) async {
    try {
      var overlay = int.parse(
        request.requestedUri.queryParameters['overlay'] ?? '0',
      );

      var body = await _readLimitedBody(request);
      var jsonBody = await decodeJsonInIsolate(body);
      // 先完整解析再覆盖写入：解析失败不清空本地数据
      final users = <FollowUser>[];
      for (var item in jsonBody) {
        users.add(FollowUser.fromJson(item));
      }
      await DBService.instance.mergeFollows(users, overlay: overlay == 1);

      unawaited(SmartDialog.showToast('已同步关注用户列表'));
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({'status': true, 'message': 'success'});
    } catch (e) {
      return toJsonResponse({'status': false, 'message': e.toString()});
    }
  }

  /// 同步标签列表
  Future<shelf.Response> _syncFollowUserTagRequest(
    shelf.Request request,
  ) async {
    try {
      var overlay = int.parse(
        request.requestedUri.queryParameters['overlay'] ?? '0',
      );

      var body = await _readLimitedBody(request);
      var jsonBody = await decodeJsonInIsolate(body);
      // 先完整解析再覆盖写入：解析失败不清空本地数据
      final tags = <FollowUserTag>[];
      for (var item in jsonBody) {
        tags.add(FollowUserTag.fromJson(item));
      }
      await DBService.instance.mergeTags(tags, overlay: overlay == 1);

      unawaited(SmartDialog.showToast('已同步标签列表'));
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({'status': true, 'message': 'success'});
    } catch (e) {
      return toJsonResponse({'status': false, 'message': e.toString()});
    }
  }

  /// 同步观看记录
  Future<shelf.Response> _syncHistoryReuqest(shelf.Request request) async {
    try {
      var overlay = int.parse(
        request.requestedUri.queryParameters['overlay'] ?? '0',
      );
      var body = await _readLimitedBody(request);
      var jsonBody = await decodeJsonInIsolate(body);
      // 先完整解析再覆盖写入：解析失败不清空本地数据
      final histories = <History>[];
      for (var item in jsonBody) {
        histories.add(History.fromJson(item));
      }
      // 先在内存里比完新旧，再一次性落盘（见 DBService.mergeHistories）
      await DBService.instance.mergeHistories(histories, overlay: overlay == 1);

      unawaited(SmartDialog.showToast('已同步观看记录'));
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
      return toJsonResponse({'status': true, 'message': 'success'});
    } catch (e) {
      return toJsonResponse({'status': false, 'message': e.toString()});
    }
  }

  /// 同步弹幕屏蔽词
  Future<shelf.Response> _syncBlockedWordReuqest(shelf.Request request) async {
    try {
      var overlay = int.parse(
        request.requestedUri.queryParameters['overlay'] ?? '0',
      );
      var body = await _readLimitedBody(request);
      var jsonBody = await decodeJsonInIsolate(body);
      if (overlay == 1) {
        await onClearShieldWords();
      }
      for (var keyword in jsonBody) {
        onAddShieldWord(keyword.trim());
      }
      unawaited(SmartDialog.showToast('已同步弹幕屏蔽词'));
      return toJsonResponse({'status': true, 'message': 'success'});
    } catch (e) {
      return toJsonResponse({'status': false, 'message': e.toString()});
    }
  }

  /// 同步哔哩哔哩账号
  Future<shelf.Response> _syncBiliAccountReuqest(shelf.Request request) async {
    try {
      var body = await _readLimitedBody(request);
      var jsonBody = await decodeJsonInIsolate(body);
      var cookie = jsonBody['cookie'];
      BiliBiliAccountService.instance.setCookie(cookie);
      unawaited(BiliBiliAccountService.instance.loadUserInfo());
      unawaited(SmartDialog.showToast('已同步哔哩哔哩账号'));
      return toJsonResponse({'status': true, 'message': 'success'});
    } catch (e) {
      return toJsonResponse({'status': false, 'message': e.toString()});
    }
  }

  shelf.Response toJsonResponse(Map<String, dynamic> data) {
    return shelf.Response.ok(
      json.encode(data),
      headers: {'Content-Type': 'application/json'},
      encoding: Encoding.getByName('utf-8'),
    );
  }

  @override
  void onClose() {
    Log.d('SyncService close');
    unawaited(_udpSubscription?.cancel());
    _udpSubscription = null;
    final socket = udp;
    udp = null;
    socket?.close();
    unawaited(server?.close(force: true));
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
