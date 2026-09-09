import 'package:dio/dio.dart';

/// Every failure the app can surface, as a closed set.
///
/// Screens switch on `kind`, never on message text, mirroring the backend's own
/// rule that clients switch on `error.code`.
enum ApiErrorKind {
  network,
  timeout,
  validation,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  rateLimited,
  insufficientBalance,
  server,
  unknown,
}

/// A failure already translated into something a person can read.
///
/// `code` keeps the backend's machine-readable code for logic; `message` is the
/// user-facing text. Raw server messages are only carried through for the codes
/// where the backend text is genuinely written for end users (validation).
class ApiException implements Exception {
  const ApiException({
    required this.kind,
    required this.message,
    this.code,
    this.statusCode,
    this.fieldErrors = const {},
  });

  final ApiErrorKind kind;
  final String message;
  final String? code;
  final int? statusCode;

  /// Field name -> message, from the backend's `details` array on a 400.
  final Map<String, String> fieldErrors;

  bool get isAuthFailure => kind == ApiErrorKind.unauthorized;
  bool get isRetryable =>
      kind == ApiErrorKind.network ||
      kind == ApiErrorKind.timeout ||
      kind == ApiErrorKind.server;

  @override
  String toString() => 'ApiException($kind, code: $code): $message';
}

/// Translates Dio failures and backend error envelopes into [ApiException].
///
/// The backend's shape is always `{ error: { code, message, details } }`.
class ApiErrorMapper {
  const ApiErrorMapper._();

  static ApiException fromDioException(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return const ApiException(
          kind: ApiErrorKind.timeout,
          message: 'That took too long. Check your connection and try again.',
        );
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return const ApiException(
          kind: ApiErrorKind.network,
          message: "You're offline. Reconnect and try again.",
        );
      case DioExceptionType.cancel:
        return const ApiException(
          kind: ApiErrorKind.unknown,
          message: 'Request cancelled.',
        );
      case DioExceptionType.badCertificate:
        return const ApiException(
          kind: ApiErrorKind.network,
          message: 'Could not establish a secure connection.',
        );
      case DioExceptionType.badResponse:
        return fromResponse(e.response);
    }
  }

  static ApiException fromResponse(Response<dynamic>? response) {
    final status = response?.statusCode ?? 0;
    final data = response?.data;

    String? code;
    String? serverMessage;
    final fieldErrors = <String, String>{};

    if (data is Map && data['error'] is Map) {
      final error = data['error'] as Map;
      code = error['code'] as String?;
      serverMessage = error['message'] as String?;

      // Validation failures carry a details array of {field, message}.
      final details = error['details'];
      if (details is List) {
        for (final item in details) {
          if (item is Map && item['field'] != null) {
            fieldErrors[item['field'].toString()] =
                (item['message'] ?? 'Invalid value').toString();
          }
        }
      }
    }

    return switch (status) {
      400 => ApiException(
        kind: ApiErrorKind.validation,
        // Validation text is written for end users, so it is safe to show.
        message: serverMessage ?? 'Please check the details and try again.',
        code: code,
        statusCode: status,
        fieldErrors: fieldErrors,
      ),
      401 => ApiException(
        kind: ApiErrorKind.unauthorized,
        message: code == 'otp_expired'
            ? 'That code has expired. Request a new one.'
            : serverMessage ?? 'Please sign in again.',
        code: code,
        statusCode: status,
      ),
      402 => ApiException(
        kind: ApiErrorKind.insufficientBalance,
        message: serverMessage ?? 'You need more coins to do that.',
        code: code,
        statusCode: status,
      ),
      403 => ApiException(
        kind: ApiErrorKind.forbidden,
        message: serverMessage ?? "You don't have access to that.",
        code: code,
        statusCode: status,
      ),
      404 => ApiException(
        kind: ApiErrorKind.notFound,
        message: "We couldn't find that.",
        code: code,
        statusCode: status,
      ),
      409 => ApiException(
        kind: ApiErrorKind.conflict,
        message: serverMessage ?? 'That is no longer available.',
        code: code,
        statusCode: status,
      ),
      429 => ApiException(
        kind: ApiErrorKind.rateLimited,
        message: 'Too many attempts. Please wait a moment and try again.',
        code: code,
        statusCode: status,
      ),
      // Server text is never surfaced for 5xx — it can leak internals.
      >= 500 => ApiException(
        kind: ApiErrorKind.server,
        message: 'Moco is having trouble right now. Please try again shortly.',
        code: code,
        statusCode: status,
      ),
      _ => ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Something went wrong. Please try again.',
        code: code,
        statusCode: status,
      ),
    };
  }

  /// Normalises anything thrown inside the data layer.
  static ApiException from(Object error) {
    if (error is ApiException) return error;
    if (error is DioException) return fromDioException(error);
    return const ApiException(
      kind: ApiErrorKind.unknown,
      message: 'Something went wrong. Please try again.',
    );
  }
}
