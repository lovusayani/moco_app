import 'package:flutter_test/flutter_test.dart';
import 'package:moco/core/api/live_api.dart';
import 'package:moco/core/errors/api_exception.dart';
import 'package:moco/features/live/live_controller.dart';
import 'package:moco/shared/models/live.dart';

/// Answers with the queued pages in order (the last one repeats).
class _ScriptedLiveApi implements LiveApi {
  _ScriptedLiveApi(this.pages);

  final List<LiveModelsPage> pages;
  int calls = 0;

  @override
  Future<LiveModelsPage> models({required int limit, int offset = 0}) async {
    final page = pages[calls < pages.length ? calls : pages.length - 1];
    calls++;
    return page;
  }

  @override
  Future<LiveConfig> config() => throw UnimplementedError();
}

const _warming = LiveModelsPage(
  available: true,
  models: [],
  freshness: 'warming',
  retryAfterMs: 5,
);

LiveModel _m(String name) => LiveModel(id: 1, username: name);

Future<void> _settle(LiveModelsController c) async {
  for (var i = 0; i < 200 && c.state.isLoading; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('warm/stale answer: models shown at once', () async {
    final api = _ScriptedLiveApi([
      LiveModelsPage(available: true, models: [_m('a')], freshness: 'stale'),
    ]);
    final c = LiveModelsController(api, 24);
    await c.load();
    expect(c.state.isLoading, isFalse);
    expect(c.state.error, isNull);
    expect(c.state.models.single.username, 'a');
    expect(api.calls, 1);
  });

  test(
    '"warming": keeps loading and asks again until the list is ready',
    () async {
      final api = _ScriptedLiveApi([
        _warming,
        _warming,
        LiveModelsPage(available: true, models: [_m('ready')]),
      ]);
      final c = LiveModelsController(api, 24);
      await c.load();
      expect(
        c.state.isLoading,
        isTrue,
        reason: 'no timeout error while warming',
      );
      expect(c.state.error, isNull);
      await _settle(c);
      expect(c.state.error, isNull);
      expect(c.state.models.single.username, 'ready');
      expect(api.calls, 3);
    },
  );

  test(
    '"warming" for too long: a retryable error, then Try again works',
    () async {
      final api = _ScriptedLiveApi([_warming]);
      final c = LiveModelsController(api, 24);
      await c.load();
      await _settle(c);
      expect(c.state.isLoading, isFalse);
      expect(c.state.error?.kind, ApiErrorKind.timeout);
      expect(api.calls, LiveModelsController.maxWarmingRetries + 1);

      api.pages
        ..clear()
        ..add(LiveModelsPage(available: true, models: [_m('back')]));
      api.calls = 0;
      await c.refresh();
      expect(c.state.error, isNull);
      expect(c.state.models.single.username, 'back');
    },
  );

  test('provider down with no recent list: a clear, retryable error', () async {
    final api = _ScriptedLiveApi([
      const LiveModelsPage(
        available: true,
        models: [],
        freshness: 'unavailable',
      ),
    ]);
    final c = LiveModelsController(api, 24);
    await c.load();
    expect(c.state.isLoading, isFalse);
    expect(c.state.error?.kind, ApiErrorKind.server);
    expect(c.state.error?.message, contains('isn’t reachable'));
  });

  test('page parsing: freshness and retry hint', () {
    final p = LiveModelsPage.fromJson({
      'available': true,
      'models': <Object>[],
      'freshness': 'warming',
      'retryAfterMs': 3000,
    });
    expect(p.isWarming, isTrue);
    expect(p.retryAfterMs, 3000);
    expect(LiveModelsPage.fromJson({'available': true}).freshness, 'fresh');
  });
}
