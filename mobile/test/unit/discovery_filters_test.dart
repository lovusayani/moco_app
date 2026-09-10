import 'package:flutter_test/flutter_test.dart';
import 'package:moco/core/api/listeners_api.dart';

void main() {
  group('DiscoveryFilters query building', () {
    test('sends only pagination when nothing is filtered', () {
      final query = const DiscoveryFilters().toQuery(limit: 20, offset: 0);

      expect(query, {'limit': 20, 'offset': 0});
      // Absent filters must not be sent as nulls — the backend's zod schema
      // rejects an explicit null where it expects an enum or nothing.
      expect(query.containsKey('language'), isFalse);
      expect(query.containsKey('gender'), isFalse);
      expect(query.containsKey('online'), isFalse);
    });

    test('includes only the filters the backend supports', () {
      final query = const DiscoveryFilters(
        language: 'hi',
        gender: 'female',
        onlineOnly: true,
      ).toQuery(limit: 10, offset: 20);

      expect(query['language'], 'hi');
      expect(query['gender'], 'female');
      expect(query['online'], true);
      expect(query['limit'], 10);
      expect(query['offset'], 20);
    });

    test('online:false is omitted rather than sent', () {
      // The backend treats the param as "online only"; sending false would be
      // read as a filter rather than as "no preference".
      final query = const DiscoveryFilters(onlineOnly: false)
          .toQuery(limit: 20, offset: 0);
      expect(query.containsKey('online'), isFalse);
    });
  });

  group('DiscoveryFilters state', () {
    test('isActive reflects whether any filter is set', () {
      expect(const DiscoveryFilters().isActive, isFalse);
      expect(const DiscoveryFilters(onlineOnly: true).isActive, isTrue);
      expect(const DiscoveryFilters(language: 'te').isActive, isTrue);
      expect(const DiscoveryFilters(gender: 'male').isActive, isTrue);
    });

    test('copyWith can clear a filter, which copyWith(null) cannot', () {
      const filters = DiscoveryFilters(language: 'hi', gender: 'female');

      // Passing null means "leave unchanged", so an explicit clear flag exists.
      expect(filters.copyWith(language: null).language, 'hi');
      expect(filters.copyWith(clearLanguage: true).language, isNull);
      expect(filters.copyWith(clearLanguage: true).gender, 'female');
      expect(filters.copyWith(clearGender: true).gender, isNull);
    });

    test('equality drives whether a reload is needed', () {
      const a = DiscoveryFilters(language: 'hi', onlineOnly: true);
      const b = DiscoveryFilters(language: 'hi', onlineOnly: true);
      const c = DiscoveryFilters(language: 'te', onlineOnly: true);

      expect(a, equals(b));
      expect(a == c, isFalse);
    });
  });
}
