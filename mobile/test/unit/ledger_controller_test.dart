import 'package:flutter_test/flutter_test.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/features/profile/ledger_controller.dart';

LedgerRow _row(int id) => LedgerRow(
  id: id,
  label: 'Row $id',
  delta: id.isEven ? 10 : -10,
  balanceAfter: 100,
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  test('loads the first page', () async {
    final controller = LedgerController(({limit = 30, before}) async {
      return ([_row(3), _row(2)], 2);
    });
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.rows.map((r) => r.id), [3, 2]);
    expect(controller.state.hasMore, isTrue);
    expect(controller.state.isLoading, isFalse);
  });

  test('an empty first page is not an error', () async {
    final controller = LedgerController(({limit = 30, before}) async => (<LedgerRow>[], null));
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.isEmpty, isTrue);
    expect(controller.state.error, isNull);
  });

  test('a failed first load is fatal', () async {
    final controller = LedgerController(({limit = 30, before}) async {
      throw const ApiException(kind: ApiErrorKind.network, message: 'offline');
    });
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.isFatalError, isTrue);
  });

  test('loadMore appends using the cursor and dedupes overlapping rows', () async {
    var calls = 0;
    final controller = LedgerController(({limit = 30, before}) async {
      calls++;
      if (before == null) return ([_row(5), _row(4)], 4);
      expect(before, 4);
      // Overlapping row 4 must not be duplicated.
      return ([_row(4), _row(3)], null);
    });
    await Future<void>.delayed(Duration.zero);

    await controller.loadMore();

    expect(controller.state.rows.map((r) => r.id), [5, 4, 3]);
    expect(controller.state.hasMore, isFalse);
    expect(calls, 2);
  });

  test('loadMore does nothing once the ledger has ended', () async {
    var calls = 0;
    final controller = LedgerController(({limit = 30, before}) async {
      calls++;
      return ([_row(1)], null);
    });
    await Future<void>.delayed(Duration.zero);

    await controller.loadMore();

    expect(calls, 1);
  });

  test('a failed loadMore keeps the rows already on screen', () async {
    final controller = LedgerController(({limit = 30, before}) async {
      if (before == null) return ([_row(2)], 2);
      throw const ApiException(kind: ApiErrorKind.network, message: 'offline');
    });
    await Future<void>.delayed(Duration.zero);

    await controller.loadMore();

    expect(controller.state.rows.map((r) => r.id), [2]);
    expect(controller.state.error, isNotNull);
    expect(controller.state.isFatalError, isFalse);
  });
}
