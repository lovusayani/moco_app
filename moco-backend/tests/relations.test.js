'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');

const { createApp } = require('../src/app');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const queues = require('../src/workers/queues');
const { resetDb, createUser } = require('./helpers');
const { signToken } = require('../src/middleware/auth');

let server;
let baseUrl;

test.before(async () => {
  await resetDb();
  server = http.createServer(createApp());
  await new Promise((resolve) => server.listen(0, resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await queues.closeAll();
  await db.close();
  await redisConfig.close();
});

async function call(method, path, { token, body } = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

async function approvedListener(name = 'Priya') {
  const user = await createUser({ listener: true });
  await db.query('UPDATE users SET display_name = $2 WHERE id = $1', [user.id, name]);
  await db.query('UPDATE listener_profiles SET is_online = TRUE WHERE user_id = $1', [user.id]);
  return user;
}

const relationCount = async (userId, listenerId, kind) =>
  Number(
    (
      await db.query(
        'SELECT count(*)::int AS c FROM listener_relations WHERE user_id=$1 AND listener_id=$2 AND kind=$3',
        [userId, listenerId, kind],
      )
    ).rows[0].c,
  );

test('favouriting requires authentication', async () => {
  await resetDb();
  const listener = await approvedListener();
  const result = await call('PUT', `/api/listeners/${listener.id}/favorite`);
  assert.equal(result.status, 401);
});

test('favourite and follow persist to the backend', async () => {
  await resetDb();
  const user = await createUser({ balance: 100 });
  const listener = await approvedListener();
  const token = signToken(user);

  for (const kind of ['favorite', 'follow']) {
    const result = await call('PUT', `/api/listeners/${listener.id}/${kind}`, { token });
    assert.equal(result.status, 200);
    assert.equal(result.body.active, true);
    assert.equal(await relationCount(user.id, listener.id, kind), 1);
  }
});

test('repeating a favourite is idempotent, not a duplicate or an error', async () => {
  await resetDb();
  const user = await createUser({ balance: 100 });
  const listener = await approvedListener();
  const token = signToken(user);

  for (let i = 0; i < 3; i += 1) {
    const result = await call('PUT', `/api/listeners/${listener.id}/favorite`, { token });
    assert.equal(result.status, 200, 'a repeat must succeed');
    assert.equal(result.body.active, true);
  }

  // The primary key guarantees this, which is what makes client retries safe.
  assert.equal(await relationCount(user.id, listener.id, 'favorite'), 1);
});

test('removing a relation that was never set is harmless', async () => {
  await resetDb();
  const user = await createUser({ balance: 100 });
  const listener = await approvedListener();

  const result = await call('DELETE', `/api/listeners/${listener.id}/favorite`, {
    token: signToken(user),
  });
  assert.equal(result.status, 200);
  assert.equal(result.body.active, false);
});

test('favourite and follow are independent', async () => {
  await resetDb();
  const user = await createUser({ balance: 100 });
  const listener = await approvedListener();
  const token = signToken(user);

  await call('PUT', `/api/listeners/${listener.id}/favorite`, { token });
  await call('PUT', `/api/listeners/${listener.id}/follow`, { token });
  await call('DELETE', `/api/listeners/${listener.id}/favorite`, { token });

  assert.equal(await relationCount(user.id, listener.id, 'favorite'), 0);
  assert.equal(await relationCount(user.id, listener.id, 'follow'), 1);
});

test('the profile reports the viewer own relation state', async () => {
  await resetDb();
  const user = await createUser({ balance: 100 });
  const other = await createUser({ balance: 100 });
  const listener = await approvedListener();
  const token = signToken(user);

  await call('PUT', `/api/listeners/${listener.id}/follow`, { token });

  const mine = await call('GET', `/api/listeners/${listener.id}`, { token });
  assert.equal(mine.body.isFollowing, true);
  assert.equal(mine.body.isFavorited, false);
  assert.equal(mine.body.followerCount, 1);

  // Another viewer sees the same count but their OWN relation state.
  const theirs = await call('GET', `/api/listeners/${listener.id}`, {
    token: signToken(other),
  });
  assert.equal(theirs.body.isFollowing, false);
  assert.equal(theirs.body.followerCount, 1);
});

test('follower count reflects multiple followers', async () => {
  await resetDb();
  const listener = await approvedListener();
  for (let i = 0; i < 3; i += 1) {
    const follower = await createUser({ balance: 10 });
    await call('PUT', `/api/listeners/${listener.id}/follow`, {
      token: signToken(follower),
    });
  }

  const viewer = await createUser({ balance: 10 });
  const result = await call('GET', `/api/listeners/${listener.id}`, {
    token: signToken(viewer),
  });
  assert.equal(result.body.followerCount, 3);
});

test('you cannot follow yourself', async () => {
  await resetDb();
  const listener = await approvedListener();
  const result = await call('PUT', `/api/listeners/${listener.id}/follow`, {
    token: signToken(listener),
  });
  assert.equal(result.status, 400);
  assert.equal(result.body.error.code, 'self_relation');
});

test('an unknown or unapproved listener cannot be followed', async () => {
  await resetDb();
  const user = await createUser({ balance: 100 });
  const token = signToken(user);

  assert.equal((await call('PUT', '/api/listeners/999999/follow', { token })).status, 404);

  const pending = await createUser({ listener: true });
  await db.query(`UPDATE listener_profiles SET kyc_status = 'pending' WHERE user_id = $1`, [
    pending.id,
  ]);
  assert.equal(
    (await call('PUT', `/api/listeners/${pending.id}/follow`, { token })).status,
    404,
  );
});

test('an invalid relation kind is rejected', async () => {
  await resetDb();
  const user = await createUser({ balance: 100 });
  const listener = await approvedListener();
  const result = await call('PUT', `/api/listeners/${listener.id}/bookmark`, {
    token: signToken(user),
  });
  assert.equal(result.status, 400);
});

test('relations cascade when a user row is removed', async () => {
  await resetDb();
  // Balance 0 so the user has no ledger rows. A user WITH financial history
  // cannot be hard-deleted at all — coin_ledger is append-only and rejects the
  // cascading DELETE — which is why the app soft-deletes accounts instead.
  const user = await createUser({ balance: 0 });
  const listener = await approvedListener();
  await call('PUT', `/api/listeners/${listener.id}/follow`, { token: signToken(user) });
  assert.equal(await relationCount(user.id, listener.id, 'follow'), 1);

  await db.query('DELETE FROM users WHERE id = $1', [user.id]);
  assert.equal(await relationCount(user.id, listener.id, 'follow'), 0);
});

test('a user with financial history cannot be hard-deleted', async () => {
  await resetDb();
  const user = await createUser({ balance: 100 });

  // The append-only ledger blocks the cascade. This is the guarantee that makes
  // soft-delete the only account-removal path.
  await assert.rejects(
    () => db.query('DELETE FROM users WHERE id = $1', [user.id]),
    /append-only/,
  );
});
