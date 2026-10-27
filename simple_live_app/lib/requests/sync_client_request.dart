import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'package:simple_live_shared/requests/http_client.dart';
import 'package:simple_live_shared/requests/http_error.dart';
import 'package:simple_live_app/services/sync_service.dart';

class SyncClientRequest {
  static const String _tokenHeader = SyncService.syncTokenHeader;

  /// 会话令牌缓存：键为客户端地址。一次同步会话（关注/标签/历史/屏蔽词/
  /// 账号往往连发多次）不再为每次操作都打一次 /info 握手。
  /// 服务端重启会轮换令牌——写请求收到 403 时清缓存重新握手并重试一次，
  /// 表现上与旧行为一致（对端重启后自动恢复），只是少了每次的额外往返
  final Map<String, String> _tokens = {};

  /// 与目标端握手换取令牌
  Future<String> _fetchToken(SyncClinet client) async {
    var data = await HttpClient.instance
        .getJson("http://${client.address}:${client.port}/info");
    if (data is Map) {
      return data['token']?.toString() ?? "";
    }
    return "";
  }

  /// 本机设备名缓存：写请求头里带给对端做配对确认展示
  String? _clientName;

  Future<String> _clientNameFor() async {
    var name = _clientName;
    if (name == null) {
      name = _clientName = await SyncService.instance.getDeviceName();
    }
    return name;
  }

  Future<String> _tokenFor(SyncClinet client) async {
    var cached = _tokens[client.address];
    if (cached != null) return cached;
    var token = await _fetchToken(client);
    if (token.isNotEmpty) {
      _tokens[client.address] = token;
    }
    return token;
  }

  /// 带鉴权的写请求：令牌失效（对端重启轮换）时重新握手重试一次
  Future<dynamic> _postWithAuth(
    SyncClinet client,
    String url,
    dynamic body, {
    Map<String, dynamic>? queryParameters,
  }) async {
    try {
      return await HttpClient.instance.postJson(
        url,
        data: body,
        header: {
          _tokenHeader: await _tokenFor(client),
          SyncService.syncClientHeader: await _clientNameFor(),
        },
        queryParameters: queryParameters,
      );
    } on HttpError catch (e) {
      if (e.statusCode != 403) rethrow;
      _tokens.remove(client.address);
      return await HttpClient.instance.postJson(
        url,
        data: body,
        header: {
          _tokenHeader: await _fetchToken(client),
          SyncService.syncClientHeader: await _clientNameFor(),
        },
        queryParameters: queryParameters,
      );
    }
  }

  Future<SyncClientInfoModel> getClientInfo(SyncClinet client) async {
    var url = "http://${client.address}:${client.port}/info";
    var data = await HttpClient.instance.getJson(url);
    // 握手响应自带本次令牌：顺手入缓存，后续写请求直接复用
    if (data is Map && data['token'] != null) {
      _tokens[client.address] = data['token'].toString();
    }
    return SyncClientInfoModel.fromJson(data);
  }

  Future<bool> syncFollow(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) async {
    var url = "http://${client.address}:${client.port}/sync/follow";
    var data = await _postWithAuth(
      client,
      url,
      body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncTag(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) async {
    var url = "http://${client.address}:${client.port}/sync/tag";
    var data = await _postWithAuth(
      client,
      url,
      body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncHistory(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) async {
    var url = "http://${client.address}:${client.port}/sync/history";
    var data = await _postWithAuth(
      client,
      url,
      body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncBlockedWord(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) async {
    var url = "http://${client.address}:${client.port}/sync/blocked_word";
    var data = await _postWithAuth(
      client,
      url,
      body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncBiliAccount(SyncClinet client, String cookie) async {
    var url = "http://${client.address}:${client.port}/sync/account/bilibili";
    var data = await _postWithAuth(
      client,
      url,
      {
        "cookie": cookie,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }
}
