import 'package:simple_live_core/src/common/core_error.dart';
import 'package:dio/dio.dart';

import 'custom_interceptor.dart';

class HttpClient {
  static HttpClient? _httpUtil;

  static HttpClient get instance {
    _httpUtil ??= HttpClient();
    return _httpUtil!;
  }

  late Dio dio;
  HttpClient() {
    dio = Dio(
      BaseOptions(
        // 连接超时只能在 BaseOptions 层设置：dio 5.9 的 Options 已无
        // connectTimeout 参数，单请求无法覆盖它。各方法的 timeout 参数
        // 只作用于 receive/send 两个阶段。
        connectTimeout: Duration(seconds: 20),
        receiveTimeout: Duration(seconds: 20),
        sendTimeout: Duration(seconds: 20),
      ),
    );
    dio.interceptors.add(CustomInterceptor());
  }

  /// 统一把底层异常转成 CoreError：
  /// - cancel 保留取消语义（isCancel），调用方可区分"主动取消"与真失败
  /// - badResponse 保留服务端状态码
  /// - 超时/连接失败给出可读信息，原始异常挂在 cause 上不丢失
  CoreError _wrapError(Object e) {
    if (e is DioException) {
      if (e.type == DioExceptionType.cancel) {
        return CoreError("请求已取消", isCancel: true, cause: e);
      }
      if (e.type == DioExceptionType.badResponse) {
        return CoreError(
          e.message ?? "",
          statusCode: e.response?.statusCode ?? 0,
          cause: e,
        );
      }
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return CoreError("连接超时，请检查网络后重试", cause: e);
      }
      return CoreError("网络连接失败，请检查网络后重试", cause: e);
    }
    return CoreError("网络请求失败", cause: e);
  }

  /// Get请求，返回String
  /// * [url] 请求链接
  /// * [queryParameters] 请求参数
  /// * [cancel] 任务取消Token
  Future<String> getText(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? header,
    CancelToken? cancel,
    Duration? timeout,
  }) async {
    try {
      queryParameters ??= {};
      header ??= {};
      var result = await dio.get(
        url,
        queryParameters: queryParameters,
        options: Options(
          responseType: ResponseType.plain,
          headers: header,
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
        cancelToken: cancel,
      );
      return result.data;
    } catch (e) {
      throw _wrapError(e);
    }
  }

  /// Get请求，返回Map
  /// * [url] 请求链接
  /// * [queryParameters] 请求参数
  /// * [cancel] 任务取消Token
  Future<dynamic> getJson(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? header,
    CancelToken? cancel,
    Duration? timeout,
  }) async {
    try {
      queryParameters ??= {};
      header ??= {};
      var result = await dio.get(
        url,
        queryParameters: queryParameters,
        options: Options(
          responseType: ResponseType.json,
          headers: header,
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
        cancelToken: cancel,
      );
      return result.data;
    } catch (e) {
      throw _wrapError(e);
    }
  }

  /// Post请求，返回Map
  /// * [url] 请求链接
  /// * [queryParameters] 请求参数
  /// * [data] 内容
  /// * [cancel] 任务取消Token
  Future<dynamic> postJson(
    String url, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Map<String, dynamic>? header,
    bool formUrlEncoded = false,
    CancelToken? cancel,
    Duration? timeout,
  }) async {
    try {
      queryParameters ??= {};
      header ??= {};
      data ??= {};
      var result = await dio.post(
        url,
        queryParameters: queryParameters,
        data: data,
        options: Options(
          responseType: ResponseType.json,
          headers: header,
          contentType:
              formUrlEncoded ? Headers.formUrlEncodedContentType : null,
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
        cancelToken: cancel,
      );
      return result.data;
    } catch (e) {
      throw _wrapError(e);
    }
  }

  /// Head请求，返回Response
  /// * [url] 请求链接
  /// * [queryParameters] 请求参数
  /// * [cancel] 任务取消Token
  Future<Response> head(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? header,
    CancelToken? cancel,
    Duration? timeout,
  }) async {
    try {
      queryParameters ??= {};
      header ??= {};
      var result = await dio.head(
        url,
        queryParameters: queryParameters,
        options: Options(
          headers: header,
          receiveDataWhenStatusError: true,
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
        cancelToken: cancel,
      );
      return result;
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.badResponse) {
        // HEAD 只用于探测/取 cookie，badResponse 原样带回给调用方判断
        return e.response!;
      }
      throw _wrapError(e);
    }
  }
}
