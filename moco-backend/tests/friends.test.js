'use strict';

/**
 * Friend requests and the chat gate they control. Disposable local test
 * database only.
 *
 * - Requests go only to active, eligible creators; every other target gets
 *   the same generic answer (no enumeration).
 * - A rejection starts a server-side cooldown; repeats never re-notify.
 * - Accepted friendship unlocks user → creator chat; rejection does not.
 * - Block overrides everything; creators may start chats.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');

const { createApp } = require('../src/app');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const { resetDb, createUser } = require('./helpers');
const { signToken } = require('../src/middleware/auth');

let server;
let baseUrl;

test.before(async () => {
  server = http.createServer(createApp());
  await new Promise((resolve) => server.listen(0, resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await db.close();
  await redisConfig.close();
});

test.beforeEach(async () => {
  await resetDb();
  await db.query('TRUNCATE friend_requests RESTART IDENTITY');
});

async function call(method, path, user, body) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(user ? { Authorization: `Bearer ${signToken(user)}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

/** An eligible creator: approved KYC plus the minimum photo count. */
async function creator() {
  const user = await createUser({ listener: true });
  await db.query('UPDATE listener_profiles SET photo_count = 3 WHERE user_id = $1', [user.id]);
  return user;
}

const request = (from, to) => call('POST', `/api/friends/request/${to.id}`, from);
const respond = (who, id, accept) => call('POST', `/api/friends/respond/${id}`, who, { accept });
const message = (from, to) => call('POST', `/api/chat/${to.id}/messages`, from, { body: 'hi' });
const requestNotifications = async (userId) =>
  (
    await db.query(
      "SELECT count(*)::int AS n FROM notifications WHERE user_id = $1 AND type = 'friend_request'",
      [userId],
    )
  ).rows[0].n;

test('accepted friendship unlocks user → creator chat', async () => {
  const user = await createUser();
  const c = await creator();

  assert.equal((await message(user, c)).status, 403, 'no chat before friendship');

  const sent = await request(user, c);
  assert.equal(sent.status, 201);
  assert.equal(await requestNotifications(c.id), 1);
  assert.equal((await message(user, c)).status, 403, 'a pending request does not unlock chat');

  const accepted = await respond(c, sent.body.requestId, true);
  assert.equal(accepted.status, 200);
  assert.equal(accepted.body.status, 'accepted');

  const chat = await message(user, c);
  assert.ok([200, 201].includes(chat.status), JSON.stringify(chat.body));
});

test('rejected friendship does not unlock chat', async () => {
  const user = await createUser();
  const c = await creator();
  const { body } = await request(user, c);
  assert.equal((await respond(c, body.requestId, false)).body.status, 'rejected');
  assert.equal((await message(user, c)).status, 403);
  const accepted = await db.query(
    "SELECT count(*)::int AS n FROM notifications WHERE user_id = $1 AND type = 'friend_accepted'",
    [user.id],
  );
  assert.equal(accepted.rows[0].n, 0, 'a rejection stays quiet');
});

test('cooldown: after a rejection the same requester must wait 24h', async () => {
  const user = await createUser();
  const c = await creator();
  const { body } = await request(user, c);
  await respond(c, body.requestId, false);

  const again = await request(user, c);
  assert.equal(again.status, 429);
  assert.equal(again.body.error.code, 'rate_limited');
  assert.equal(again.body.error.message, 'You can send another request later.');
  assert.equal(await requestNotifications(c.id), 1, 'the refused retry notifies nobody');

  // The rejected row is kept as the cooldown record, not deleted.
  const kept = await db.query("SELECT count(*)::int AS n FROM friend_requests WHERE status = 'rejected'");
  assert.equal(kept.rows[0].n, 1);

  // Once the cooldown has passed, one new request is allowed.
  await db.query("UPDATE friend_requests SET responded_at = now() - interval '25 hours'");
  assert.equal((await request(user, c)).status, 201);
  assert.equal(await requestNotifications(c.id), 2);
});

test('no spam: repeated requests while pending never re-notify', async () => {
  const user = await createUser();
  const c = await creator();
  assert.equal((await request(user, c)).status, 201);
  for (let i = 0; i < 3; i += 1) {
    const dup = await request(user, c);
    assert.equal(dup.status, 400);
    assert.equal(dup.body.error.code, 'request_pending');
  }
  assert.equal(await requestNotifications(c.id), 1);

  // Burst limit: past 5 per minute everything is refused outright.
  const statuses = [];
  for (let i = 0; i < 3; i += 1) statuses.push((await request(user, c)).status);
  assert.ok(statuses.includes(429), `burst limited: ${statuses}`);
  assert.equal(await requestNotifications(c.id), 1);
});

test('requests go only to approved creators; every other target looks the same', async () => {
  const user = await createUser();
  const normal = await createUser();
  const unapproved = await createUser({ listener: true });
  await db.query("UPDATE listener_profiles SET kyc_status = 'pending', photo_count = 3 WHERE user_id = $1", [unapproved.id]);
  const noPhotos = await createUser({ listener: true }); // approved KYC, too few photos
  const inactive = await creator();
  await db.query("UPDATE users SET status = 'suspended' WHERE id = $1", [inactive.id]);
  const blocked = await creator();
  await db.query('INSERT INTO blocks (blocker_id, blocked_id) VALUES ($1, $2)', [blocked.id, user.id]);

  const answers = [];
  for (const target of [normal, unapproved, noPhotos, inactive, blocked, { id: 999999 }, user]) {
    const res = await request(user, target);
    answers.push(JSON.stringify([res.status, res.body]));
    await redisConfig.redis.flushdb(); // keep the burst limiter out of this test
  }
  assert.equal(new Set(answers).size, 1, `identical answers:\n${answers.join('\n')}`);
  assert.equal(JSON.parse(answers[0])[0], 404);

  const rows = await db.query('SELECT count(*)::int AS n FROM friend_requests');
  assert.equal(rows.rows[0].n, 0);
  const notes = await db.query("SELECT count(*)::int AS n FROM notifications WHERE type = 'friend_request'");
  assert.equal(notes.rows[0].n, 0);
});

test('normal user target is refused even for a creator sender', async () => {
  const c = await creator();
  const normal = await createUser();
  const res = await request(c, normal);
  assert.equal(res.status, 404);
  assert.equal(res.body.error.code, 'not_available');
});

test('block overrides an accepted friendship, both directions', async () => {
  const user = await createUser();
  const c = await creator();
  const { body } = await request(user, c);
  await respond(c, body.requestId, true);
  assert.ok([200, 201].includes((await message(user, c)).status));

  await db.query('INSERT INTO blocks (blocker_id, blocked_id) VALUES ($1, $2)', [c.id, user.id]);
  assert.equal((await message(user, c)).status, 403);
  assert.equal((await message(c, user)).status, 403);
});

test('a creator may start a chat with a user without a friendship', async () => {
  const c = await creator();
  const user = await createUser();
  const res = await message(c, user);
  assert.ok([200, 201].includes(res.status), JSON.stringify(res.body));
  // and the user may reply in the thread the creator started
  assert.ok([200, 201].includes((await message(user, c)).status));
});

test('an unapproved creator is not a creator for chat', async () => {
  const pending = await createUser({ listener: true });
  await db.query("UPDATE listener_profiles SET kyc_status = 'pending' WHERE user_id = $1", [pending.id]);
  const c = await creator();
  assert.equal((await message(pending, c)).status, 403);
});

test('a friend request does not change the follower count; follow does', async () => {
  const user = await createUser();
  const c = await creator();
  const count = async () => (await call('GET', `/api/listeners/${c.id}`, user)).body.followerCount;
  assert.equal(await count(), 0);
  await request(user, c);
  assert.equal(await count(), 0);
  const follow = await call('PUT', `/api/listeners/${c.id}/follow`, user);
  assert.equal(follow.status, 200);
  assert.equal(await count(), 1);
});
