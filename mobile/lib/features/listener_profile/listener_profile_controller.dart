import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/listeners_api.dart';
import '../../core/providers.dart';
import '../../shared/models/listener.dart';

/// Loads one listener profile.
final listenerProfileProvider = FutureProvider.family<ListenerDetail, int>((
  ref,
  id,
) {
  return ref.watch(listenersApiProvider).byId(id);
});

/// "Similar listeners" for the horizontal scroller.
///
/// The backend has no similarity endpoint, so this is an explicit CLIENT-SIDE
/// heuristic over the real discovery endpoint: listeners sharing the profile's
/// primary language, with the profile itself removed. It is a reasonable proxy,
/// not a backend feature — documented in mobile/README.md.
final similarListenersProvider =
    FutureProvider.family<List<ListenerSummary>, ListenerDetail>((
      ref,
      listener,
    ) async {
      final api = ref.watch(listenersApiProvider);
      final language = listener.languages.isNotEmpty
          ? listener.languages.first
          : null;

      final page = await api.discover(
        filters: DiscoveryFilters(language: language),
        limit: 10,
      );

      return page.listeners.where((l) => l.id != listener.id).take(8).toList();
    });
