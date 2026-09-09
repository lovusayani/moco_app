import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moco/core/errors/api_exception.dart';

Response<dynamic> _response(
  int status, {
  String? code,
  String? message,
  List? details,
}) {
  return Response<dynamic>(
    requestOptions: RequestOptions(path: '/test'),
    statusCode: status,
    data: {
      'error': {
        'code': code,
        'message': message,
        if (details != null) 'details': details,
      },
    },
  );
}

void main() {
  group('ApiErrorMapper status mapping', () {
    test('maps every documented status to its kind', () {
      final cases = <int, ApiErrorKind>{
        400: ApiErrorKind.validation,
        401: ApiErrorKind.unauthorized,
        402: ApiErrorKind.insufficientBalance,
        403: ApiErrorKind.forbidden,
        404: ApiErrorKind.notFound,
        409: ApiErrorKind.conflict,
        429: ApiErrorKind.rateLimited,
        500: ApiErrorKind.server,
        503: ApiErrorKind.server,
      };

      cases.forEach((status, kind) {
        expect(
          ApiErrorMapper.fromResponse(_response(status)).kind,
          kind,
          reason: 'HTTP $status should map to $kind',
        );
      });
    });

    test('keeps the backend error code for logic', () {
      final error = ApiErrorMapper.fromResponse(
        _response(409, code: 'listener_unavailable'),
      );
      expect(error.code, 'listener_unavailable');
      expect(error.kind, ApiErrorKind.conflict);
    });

    test('extracts field errors from a validation response', () {
      final error = ApiErrorMapper.fromResponse(
        _response(
          400,
          code: 'validation_failed',
          message: 'Invalid request',
          details: [
            {'field': 'displayName', 'message': 'Too short'},
            {'field': 'phone', 'message': 'Bad format'},
          ],
        ),
      );

      expect(error.fieldErrors['displayName'], 'Too short');
      expect(error.fieldErrors['phone'], 'Bad format');
    });

    test('never leaks a raw server message on a 5xx', () {
      final error = ApiErrorMapper.fromResponse(
        _response(500, message: 'ECONNREFUSED at pg pool line 42'),
      );
      expect(error.message.contains('ECONNREFUSED'), isFalse);
      expect(error.message.contains('pg pool'), isFalse);
    });

    test('surfaces a friendly message for an expired OTP', () {
      final error = ApiErrorMapper.fromResponse(
        _response(401, code: 'otp_expired'),
      );
      expect(error.message.toLowerCase(), contains('expired'));
    });
  });

  group('ApiErrorMapper transport mapping', () {
    test('connection failure maps to network, not unknown', () {
      final error = ApiErrorMapper.fromDioException(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionError,
        ),
      );
      expect(error.kind, ApiErrorKind.network);
      expect(error.isRetryable, isTrue);
    });

    test('each timeout type maps to timeout', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        final error = ApiErrorMapper.fromDioException(
          DioException(
            requestOptions: RequestOptions(path: '/x'),
            type: type,
          ),
        );
        expect(error.kind, ApiErrorKind.timeout);
      }
    });
  });

  group('retry and auth classification', () {
    test('only transient failures are retryable', () {
      expect(ApiErrorMapper.fromResponse(_response(500)).isRetryable, isTrue);
      // A validation error will fail identically on retry.
      expect(ApiErrorMapper.fromResponse(_response(400)).isRetryable, isFalse);
      expect(ApiErrorMapper.fromResponse(_response(403)).isRetryable, isFalse);
    });

    test('only 401 counts as an auth failure', () {
      expect(ApiErrorMapper.fromResponse(_response(401)).isAuthFailure, isTrue);
      expect(
        ApiErrorMapper.fromResponse(_response(403)).isAuthFailure,
        isFalse,
      );
    });
  });
}
