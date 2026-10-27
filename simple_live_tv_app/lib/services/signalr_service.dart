import 'dart:async';
import 'package:signalr_netcore/signalr_client.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/utils.dart';

enum SignalRConnectionState {
  connecting,
  connected,
  disconnected,
}

class SignalRService {
  static const String kUrl = "https://sync1.nsapps.cn/sync";

  SignalRConnectionState state = SignalRConnectionState.connecting;

  final _stateStreamController =
      StreamController<SignalRConnectionState>.broadcast();
  Stream<SignalRConnectionState> get stateStream =>
      _stateStreamController.stream;

  final _onFavoriteStreamController =
      StreamController<(bool, String)>.broadcast();
  Stream<(bool, String)> get onFavoriteStream =>
      _onFavoriteStreamController.stream;

  final _onHistoryStreamController =
      StreamController<(bool, String)>.broadcast();
  Stream<(bool, String)> get onHistoryStream =>
      _onHistoryStreamController.stream;

  final _onShieldWordStreamController =
      StreamController<(bool, String)>.broadcast();
  Stream<(bool, String)> get onShieldWordStream =>
      _onShieldWordStreamController.stream;

  final _onBiliAccountStreamController =
      StreamController<(bool, String)>.broadcast();
  Stream<(bool, String)> get onBiliAccountStream =>
      _onBiliAccountStreamController.stream;

  final _onRoomDestroyedStreamController = StreamController<String>.broadcast();
  Stream<String> get onRoomDestroyedStream =>
      _onRoomDestroyedStreamController.stream;

  final _onRoomUserUpdatedStreamController =
      StreamController<List<RoomUser>>.broadcast();
  Stream<List<RoomUser>> get onRoomUserUpdatedStream =>
      _onRoomUserUpdatedStreamController.stream;

  HubConnection? hubConnection;
  bool _disposed = false;

  /// 广播连接状态。页面 dispose 后迟到的回调（重连成功、连接失败）
  /// 直接丢弃，避免对已关闭的 StreamController add 抛 StateError
  void _emitState(SignalRConnectionState next) {
    state = next;
    if (!_stateStreamController.isClosed) {
      _stateStreamController.add(next);
    }
  }

  Future<void> connect() async {
    if (_disposed) return;
    // 重复 connect 时先停掉旧连接，避免遗留连接继续占用回调与 socket
    try {
      await hubConnection?.stop();
    } catch (_) {
      // 旧连接可能已经断开，停止失败不影响新建
    }
    hubConnection = HubConnectionBuilder()
        .withUrl(kUrl)
        // 断网/服务端重启后自动重连，退避 2s/5s/10s/20s 共 4 次；
        // 列表耗尽即停止重连——终止用的 null 由 DefaultRetryPolicy 自行追加，
        // 这里传 null 会破坏 List<int> 类型且语义重复
        .withAutomaticReconnect(
          retryDelays: [2000, 5000, 10000, 20000],
        )
        .build();
    hubConnection!.onclose(({Exception? error}) {
      _emitState(SignalRConnectionState.disconnected);
    });
    hubConnection!.onreconnected(({String? connectionId}) {
      Log.d("reconnected: $connectionId");
      _emitState(SignalRConnectionState.connected);
    });
    try {
      await hubConnection!.start();
    } catch (e) {
      // 连接失败必须落到明确状态：否则界面永远停在"连接中"
      _emitState(SignalRConnectionState.disconnected);
      rethrow;
    }
    _emitState(SignalRConnectionState.connected);
    _listen();
  }

  void _listen() {
    hubConnection?.on("onFavoriteReceived", (args) {
      _onFavoriteStreamController.add((args![0] as bool, args[1] as String));
    });
    hubConnection?.on("onHistoryReceived", (args) {
      _onHistoryStreamController.add((args![0] as bool, args[1] as String));
    });
    hubConnection?.on("onShieldWordReceived", (args) {
      _onShieldWordStreamController.add((args![0] as bool, args[1] as String));
    });
    hubConnection?.on("onBiliAccountReceived", (args) {
      _onBiliAccountStreamController.add((args![0] as bool, args[1] as String));
    });
    hubConnection?.on("onRoomDestroyed", (args) {
      _onRoomDestroyedStreamController.add(args![0].toString());
    });
    hubConnection?.on("onUserUpdated", (args) {
      var list = (args![0] as List).map((e) => RoomUser.fromObject(e)).toList();
      _onRoomUserUpdatedStreamController.add(list);
    });
  }

  Future<void> disconnect() async {
    await hubConnection?.stop();
    _emitState(SignalRConnectionState.disconnected);
  }

  Future<Resp<String>> createRoom() async {
    if (state != SignalRConnectionState.connected) {
      throw Exception("not connected");
    }
    String app = "Simple Live TV";
    String platform = 'tv';
    String version = Utils.packageInfo.version;
    var resp = await hubConnection
        ?.invoke("CreateRoom", args: [app, platform, version]);
    return Resp<String>.fromObject(resp);
  }

  Future<Resp> joinRoom(String roomId) async {
    if (state != SignalRConnectionState.connected) {
      throw Exception("not connected");
    }
    String app = "Simple Live TV";
    String platform = 'tv';
    String version = Utils.packageInfo.version;
    var resp = await hubConnection
        ?.invoke("JoinRoom", args: [roomId, app, platform, version]);
    return Resp.fromObject(resp);
  }

  Future<Resp> sendContent({
    required String roomName,
    required String action,
    required bool overlay,
    required String content,
  }) async {
    if (state != SignalRConnectionState.connected) {
      throw Exception("not connected");
    }
    var resp =
        await hubConnection?.invoke(action, args: [roomName, overlay, content]);
    return Resp.fromObject(resp);
  }

  void dispose() {
    _disposed = true;
    _stateStreamController.close();
    _onFavoriteStreamController.close();
    _onHistoryStreamController.close();
    _onShieldWordStreamController.close();
    _onBiliAccountStreamController.close();
    _onRoomDestroyedStreamController.close();
    _onRoomUserUpdatedStreamController.close();

    hubConnection?.stop();
  }
}

class Resp<T> {
  final bool isSuccess;
  final String message;
  final T? data;
  Resp(this.isSuccess, this.message, this.data);

  factory Resp.fromJson(Map<String, dynamic> json) {
    return Resp(
      json['isSuccess'],
      json['message'] ?? "",
      json['data'],
    );
  }

  factory Resp.fromObject(Object? obj) {
    if (obj is Map<String, dynamic>) {
      return Resp.fromJson(obj);
    }
    return Resp(false, "unknown", null);
  }
}

class RoomUser {
  final String connectionId;
  final String shortId;
  final String platform;
  final String version;
  final String app;
  final bool? isCreator;

  RoomUser({
    required this.connectionId,
    required this.shortId,
    required this.platform,
    required this.version,
    required this.app,
    this.isCreator = false,
  });

  factory RoomUser.fromJson(Map<String, dynamic> json) {
    return RoomUser(
      connectionId: json['connectionId'],
      shortId: json['shortId'],
      platform: json['platform'],
      version: json['version'],
      app: json['app'],
      isCreator: json['isCreator'],
    );
  }

  factory RoomUser.fromObject(Object? obj) {
    if (obj is Map<String, dynamic>) {
      return RoomUser.fromJson(obj);
    }
    return RoomUser(
      connectionId: "",
      shortId: "",
      platform: "",
      version: "",
      app: "",
    );
  }
}
