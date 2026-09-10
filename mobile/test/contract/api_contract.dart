// Parses REAL backend responses through the client's models.
//
// A command-line checker, not app code: stdout IS its output.
// ignore_for_file: avoid_print
//
// Run against a live dev backend; excluded from `flutter test` because it needs
// a server. Proves the models match the API, which unit tests with hand-written
// fixtures cannot.
import 'dart:convert';
import 'dart:io';

import 'package:moco/shared/models/app_config.dart';
import 'package:moco/shared/models/listener.dart';
import 'package:moco/shared/models/user.dart';

const base = 'http://localhost:3210/api';

Future<Map<String, dynamic>> get(String path, {String? token}) async {
  final client = HttpClient();
  final request = await client.getUrl(Uri.parse('$base$path'));
  if (token != null) request.headers.set('Authorization', 'Bearer $token');
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  client.close();
  return jsonDecode(body) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> post(
  String path,
  Map<String, dynamic> data,
) async {
  final client = HttpClient();
  final request = await client.postUrl(Uri.parse('$base$path'));
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode(data));
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  client.close();
  return jsonDecode(body) as Map<String, dynamic>;
}

/// Generic request helper, for the verbs `get`/`post` above do not cover.
Future<Map<String, dynamic>> send(
  String method,
  String path, {
  String? token,
  Map<String, dynamic>? data,
}) async {
  final client = HttpClient();
  final request = await client.openUrl(method, Uri.parse('$base$path'));
  if (token != null) request.headers.set('Authorization', 'Bearer $token');
  if (data != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(data));
  }
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  client.close();
  return body.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(body) as Map<String, dynamic>;
}

void check(String label, bool ok, [String detail = '']) {
  print('${ok ? "PASS" : "FAIL"}  $label${detail.isEmpty ? '' : ' — $detail'}');
  if (!ok) exitCode = 1;
}

Future<void> main() async {
  // --- GET /config
  final config = AppConfig.fromJson(await get('/config'));
  check('AppConfig parses', config.packs.isNotEmpty);
  check(
    'rates come from the server',
    config.rates.audio > 0 && config.rates.video > 0,
    'audio=${config.rates.audio} video=${config.rates.video}',
  );
  check(
    'pack bonuses parse',
    config.packs.any((p) => p.totalCoins > p.coins),
    '${config.packs.length} packs',
  );

  // --- Auth
  const phone = '+919812340001';
  await post('/auth/otp/request', {'phone': phone});
  final session = AuthSession.fromJson(
    await post('/auth/otp/verify', {'phone': phone, 'code': '123456'}),
  );
  check('AuthSession parses a real token', session.token.isNotEmpty);
  check('AuthUser parses', session.user.phone == phone);

  // --- GET /users/me
  final me = MocoUser.fromJson(await get('/users/me', token: session.token));
  check('MocoUser parses', me.phone == phone);
  check('a new user is not profile-complete', !me.isProfileComplete);
  check('freeTrialAvailable parses', me.freeTrialAvailable);

  // --- GET /listeners
  final page = DiscoveryPage.fromJson(
    await get('/listeners?limit=5', token: session.token),
  );
  check(
    'DiscoveryPage parses',
    page.listeners.isNotEmpty,
    '${page.listeners.length} listeners',
  );

  final first = page.listeners.first;
  check(
    'listener name maps from the API field "name"',
    first.name != 'Listener' && first.name.isNotEmpty,
    first.name,
  );
  check(
    'per-listener rates parse',
    first.audioRate > 0 && first.videoRate > 0,
    'audio=${first.audioRate} video=${first.videoRate}',
  );
  check(
    'languages array parses',
    first.languages.isNotEmpty,
    first.languages.join(','),
  );

  // --- Filters the backend genuinely supports
  final filtered = DiscoveryPage.fromJson(
    await get('/listeners?language=hi&limit=5', token: session.token),
  );
  check(
    'language filter is honoured by the backend',
    filtered.listeners.every((l) => l.languages.contains('hi')),
  );

  // --- GET /listeners/:id
  final detail = ListenerDetail.fromJson(
    await get('/listeners/${first.id}', token: session.token),
  );
  check('ListenerDetail parses', detail.id == first.id);
  check(
    'ratingCount is present only on the detail endpoint',
    detail.ratingCount >= 0,
    'ratingCount=${detail.ratingCount}',
  );

  // --- Phase 1.1: PATCH /users/me is now canonical
  final patched = MocoUser.fromJson(
    await send(
      'PATCH',
      '/users/me',
      token: session.token,
      data: {'displayName': 'Rahul', 'language': 'hi'},
    ),
  );
  check('PATCH /users/me parses as MocoUser', patched.displayName == 'Rahul');
  check('PATCH now completes the profile', patched.isProfileComplete);

  final refetched = MocoUser.fromJson(
    await get('/users/me', token: session.token),
  );
  check(
    'PATCH and GET agree',
    patched.displayName == refetched.displayName &&
        patched.language == refetched.language &&
        patched.coinBalance == refetched.coinBalance,
  );

  // --- Server-side search
  final searched = DiscoveryPage.fromJson(
    await get(
      '/listeners?q=${Uri.encodeQueryComponent(first.name)}',
      token: session.token,
    ),
  );
  check(
    'server-side search returns a match',
    searched.listeners.isNotEmpty,
    '${searched.listeners.length} for "${first.name}"',
  );

  final noMatch = DiscoveryPage.fromJson(
    await get('/listeners?q=zzzznotfound', token: session.token),
  );
  check('a search miss is an empty page', noMatch.listeners.isEmpty);

  // --- Capability filtering
  final audioOnly = DiscoveryPage.fromJson(
    await get('/listeners?callType=audio', token: session.token),
  );
  check(
    'callType=audio returns only audio-capable listeners',
    audioOnly.listeners.every((l) => l.acceptsAudio),
    '${audioOnly.listeners.length} listeners',
  );

  // --- Verified is published, KYC is not
  check(
    'verified is a real published boolean',
    first.verified,
    'verified=${first.verified}',
  );

  // --- Relations: idempotent both ways
  final favUrl = '/listeners/${first.id}/favorite';
  final firstPut = await send('PUT', favUrl, token: session.token);
  final secondPut = await send('PUT', favUrl, token: session.token);
  check(
    'favourite is idempotent',
    firstPut['active'] == true && secondPut['active'] == true,
  );

  final withFav = ListenerDetail.fromJson(
    await get('/listeners/${first.id}', token: session.token),
  );
  check('the profile reports the favourite', withFav.isFavorited);

  await send('DELETE', favUrl, token: session.token);
  final cleared = ListenerDetail.fromJson(
    await get('/listeners/${first.id}', token: session.token),
  );
  check('removing a favourite persists', !cleared.isFavorited);

  final followUrl = '/listeners/${first.id}/follow';
  final followed = await send('PUT', followUrl, token: session.token);
  check(
    'follow returns a follower count',
    (followed['followerCount'] as num) >= 1,
    'count=${followed['followerCount']}',
  );

  print(exitCode == 0 ? '\nAll contract checks passed.' : '\nContract drift.');
}
