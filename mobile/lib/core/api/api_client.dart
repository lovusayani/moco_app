import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/env.dart';
import '../errors/api_exception.dart';
import '../storage/secure_store.dart';

/// Called when the backend rejects the session, so auth state can be cleared
/// exactly once from a single place.
typedef UnauthorizedCallback = Future<void> Function();

/// Configured Dio instance for the Moco backend.
///
/// The backend issues ONE long-lived JWT — docs/API.md defines no refresh
/// endpoint — so there is deliberately no refresh-token machinery here. A 401
/// means the session is over: clear it and send the user to login.
class ApiClient {
  ApiClient({Dio? dio, SecureStore? store, this.onUnauthorized})
    : _store = store ?? FlutterSecureStore(),
      dio = dio ?? Dio() {
    this.dio
      ..options.baseUrl = Env.apiBaseUrl
      ..options.connectTimeout = Env.connectTimeout
      ..options.receiveTimeout = Env.receiveTimeout
      ..options.headers['Content-Type'] = 'application/json'
      // Non-2xx is handled by the interceptor below, not by Dio throwing raw.
      ..options.validateStatus = (status) => status != null && status < 400;

    this.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _store.readToken();
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          if (Env.enableHttpLogging) {
            // Path and method only. Never headers or bodies — the Authorization
            // header and OTP codes both travel there.
            debugPrint('→ ${options.method} ${options.path}');
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          if (Env.enableHttpLogging) {
            debugPrint(
              '← ${response.statusCode} ${response.requestOptions.path}',
            );
          }
          handler.next(response);
        },
        onError: (error, handler) async {
          final mapped = ApiErrorMapper.fromDioException(error);

          if (Env.enableHttpLogging) {
            debugPrint(
              '✗ ${mapped.statusCode ?? '-'} ${error.requestOptions.path} '
              '(${mapped.code ?? mapped.kind.name})',
            );
          }

          // A rejected OTP is a 401 too, but it is not a dead session — the user
          // has no session yet. Only drop credentials for authenticated calls.
          final isAuthEndpoint = error.requestOptions.path.startsWith('/auth/');
          if (mapped.isAuthFailure && !isAuthEndpoint) {
            await _store.clear();
            await onUnauthorized?.call();
          }

          handler.reject(
            DioException(
              requestOptions: error.requestOptions,
              response: error.response,
              type: error.type,
              error: mapped,
            ),
          );
        },
      ),
    );
  }

  final Dio dio;
  final SecureStore _store;

  /// Assigned after construction by the auth layer.
  ///
  /// Deliberately mutable rather than a constructor dependency: the API client
  /// is what DETECTS a dead session, and the auth controller is what ACTS on
  /// it, but the controller also needs the client to make its own requests.
  /// Injecting the controller here would make the two providers mutually
  /// dependent; a late-assigned callback keeps the graph acyclic.
  UnauthorizedCallback? onUnauthorized;

  /// Unwraps a request, guaranteeing an [ApiException] on every failure path.
  Future<T> request<T>(
    Future<Response<dynamic>> Function() send,
    T Function(dynamic data) parse,
  ) async {
    try {
      final response = await send();
      return parse(response.data);
    } on DioException catch (e) {
      throw e.error is ApiException
          ? e.error as ApiException
          : ApiErrorMapper.fromDioException(e);
    } catch (e) {
      throw ApiErrorMapper.from(e);
    }
  }
}
