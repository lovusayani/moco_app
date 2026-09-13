import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moco/core/api/listeners_api.dart';
import 'package:moco/core/api/payouts_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/features/profile/profile_controller.dart';
import 'package:moco/shared/models/earnings.dart';

class _MockListenersApi extends Mock implements ListenersApi {}

class _MockPayoutsApi extends Mock implements PayoutsApi {}

const _earnings = EarningsSummary(
  balance: 100,
  lifetime: 500,
  today: 10,
  thisMonth: 80,
  totalCalls: 12,
  rating: 4.5,
  minWithdrawal: 100,
  canWithdraw: true,
);

void main() {
  late _MockListenersApi listenersApi;
  late _MockPayoutsApi payoutsApi;
  late int refreshCalls;

  setUp(() {
    listenersApi = _MockListenersApi();
    payoutsApi = _MockPayoutsApi();
    refreshCalls = 0;
  });

  ProfileController subject() =>
      ProfileController(listenersApi, payoutsApi, () async => refreshCalls++);

  group('availability toggle', () {
    test('going online re-reads the user on success', () async {
      when(() => listenersApi.setOnline(true)).thenAnswer(
        (_) async => const ListenerStatusResult(isOnline: true, isBusy: false),
      );

      final controller = subject();
      await controller.setAvailability(true);

      expect(controller.state.isTogglingAvailability, isFalse);
      expect(controller.state.availabilityError, isNull);
      expect(refreshCalls, 1);
      verify(() => listenersApi.setOnline(true)).called(1);
    });

    test('a KYC refusal surfaces as an error and does not refresh', () async {
      when(() => listenersApi.setOnline(true)).thenThrow(
        const ApiException(
          kind: ApiErrorKind.validation,
          code: 'kyc_required',
          message: 'Complete verification before going online',
        ),
      );

      final controller = subject();
      await controller.setAvailability(true);

      expect(controller.state.availabilityError?.code, 'kyc_required');
      expect(refreshCalls, 0);
    });

    test('a second toggle is ignored while one is in flight', () async {
      when(() => listenersApi.setOnline(any())).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return const ListenerStatusResult(isOnline: true, isBusy: false);
      });

      final controller = subject();
      await Future.wait([
        controller.setAvailability(true),
        controller.setAvailability(false),
      ]);

      verify(() => listenersApi.setOnline(any())).called(1);
    });
  });

  group('earnings', () {
    test('loads the summary from the server', () async {
      when(() => payoutsApi.earnings()).thenAnswer((_) async => _earnings);

      final controller = subject();
      await controller.loadEarnings();

      expect(controller.state.earnings?.balance, 100);
      expect(controller.state.isLoadingEarnings, isFalse);
    });

    test('a failed load surfaces the error without a stale summary', () async {
      when(() => payoutsApi.earnings()).thenThrow(
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      );

      final controller = subject();
      await controller.loadEarnings();

      expect(controller.state.earnings, isNull);
      expect(controller.state.earningsError, isNotNull);
    });
  });
}
