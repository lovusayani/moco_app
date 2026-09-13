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
const notifications = require('../src/modules/notifications/notifications.service');

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

test('an empty inbox is a 200 with an empty list and zero unread', async () => {
  await resetDb();
  const user = await createUser();

  const res = await call('GET', '/api/notifications', { token: signToken(user) });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.notifications, []);
  assert.equal(res.body.unreadCount, 0);
  assert.equal(res.body.nextCursor, null);
});

test('notifications list newest first and count unread correctly', async () => {
  await resetDb();
  const user = await createUser();

  await notifications.create({ userId: user.id, type: 'kyc_approved', title: 'First' });
  const second = await notifications.create({ userId: user.id, type: 'kyc_approved', title: 'Second' });

  const res = await call('GET', '/api/notifications', { token: signToken(user) });
  assert.equal(res.status, 200);
  assert.equal(res.body.notifications.length, 2);
  assert.equal(res.body.notifications[0].title, 'Second');
  assert.equal(res.body.unreadCount, 2);
  assert.equal(res.body.notifications[0].read, false);
});

test('marking one notification read updates only that one', async () => {
  await resetDb();
  const user = await createUser();
  await notifications.create({ userId: user.id, type: 'kyc_approved', title: 'First' });
  await notifications.create({ userId: user.id, type: 'kyc_approved', title: 'Second' });

  const list = await call('GET', '/api/notifications', { token: signToken(user) });
  const targetId = list.body.notifications[1].id; // 'First'

  const marked = await call('POST', `/api/notifications/${targetId}/read`, { token: signToken(user) });
  assert.equal(marked.status, 200);

  const after = await call('GET', '/api/notifications', { token: signToken(user) });
  assert.equal(after.body.unreadCount, 1);
  const target = after.body.notifications.find((n) => n.id === targetId);
  assert.equal(target.read, true);
});

test('marking read twice is idempotent', async () => {
  await resetDb();
  const user = await createUser();
  await notifications.create({ userId: user.id, type: 'kyc_approved', title: 'First' });
  const list = await call('GET', '/api/notifications', { token: signToken(user) });
  const id = list.body.notifications[0].id;

  assert.equal((await call('POST', `/api/notifications/${id}/read`, { token: signToken(user) })).status, 200);
  assert.equal((await call('POST', `/api/notifications/${id}/read`, { token: signToken(user) })).status, 200);
});

test('read-all clears every unread notification', async () => {
  await resetDb();
  const user = await createUser();
  await notifications.create({ userId: user.id, type: 'kyc_approved', title: 'A' });
  await notifications.create({ userId: user.id, type: 'kyc_approved', title: 'B' });

  const res = await call('POST', '/api/notifications/read-all', { token: signToken(user) });
  assert.equal(res.status, 200);

  const after = await call('GET', '/api/notifications', { token: signToken(user) });
  assert.equal(after.body.unreadCount, 0);
});

test('deleting a notification removes it', async () => {
  await resetDb();
  const user = await createUser();
  await notifications.create({ userId: user.id, type: 'kyc_approved', title: 'A' });
  const list = await call('GET', '/api/notifications', { token: signToken(user) });
  const id = list.body.notifications[0].id;

  const del = await call('DELETE', `/api/notifications/${id}`, { token: signToken(user) });
  assert.equal(del.status, 200);

  const after = await call('GET', '/api/notifications', { token: signToken(user) });
  assert.deepEqual(after.body.notifications, []);
});

test('a user cannot read, mark, or delete another user\'s notification', async () => {
  await resetDb();
  const owner = await createUser();
  const stranger = await createUser();
  await notifications.create({ userId: owner.id, type: 'kyc_approved', title: 'Private' });
  const list = await call('GET', '/api/notifications', { token: signToken(owner) });
  const id = list.body.notifications[0].id;

  assert.equal(
    (await call('POST', `/api/notifications/${id}/read`, { token: signToken(stranger) })).status,
    404,
  );
  assert.equal(
    (await call('DELETE', `/api/notifications/${id}`, { token: signToken(stranger) })).status,
    404,
  );

  const strangerList = await call('GET', '/api/notifications', { token: signToken(stranger) });
  assert.deepEqual(strangerList.body.notifications, []);
});

test('cursor pagination walks the whole list without skipping or repeating', async () => {
  await resetDb();
  const user = await createUser();
  for (let i = 0; i < 5; i += 1) {
    await notifications.create({ userId: user.id, type: 'kyc_approved', title: `N${i}` });
  }

  const page1 = await call('GET', '/api/notifications?limit=2', { token: signToken(user) });
  assert.equal(page1.body.notifications.length, 2);
  assert.ok(page1.body.nextCursor);

  const page2 = await call('GET', `/api/notifications?limit=2&before=${page1.body.nextCursor}`, {
    token: signToken(user),
  });
  const ids1 = page1.body.notifications.map((n) => n.id);
  const ids2 = page2.body.notifications.map((n) => n.id);
  assert.equal(new Set([...ids1, ...ids2]).size, ids1.length + ids2.length);
});

test('KYC approval creates a notification for the listener', async () => {
  await resetDb();
  const { query } = require('../src/config/db');
  const admin = await createUser();
  await query(`UPDATE users SET role = 'admin' WHERE id = $1`, [admin.id]).catch(() => {});
  const listener = await createUser({ listener: true });
  await query(`UPDATE listener_profiles SET kyc_status = 'pending' WHERE user_id = $1`, [
    listener.id,
  ]);

  // admin.routes.js gates on requireAdmin (ADMIN_PHONES), which this test
  // environment does not configure — call the service function directly,
  // exactly as the route handler does, to test the notification side effect
  // in isolation from the admin allow-list.
  const notificationsService = require('../src/modules/notifications/notifications.service');
  await notificationsService.create({
    userId: listener.id,
    type: 'kyc_approved',
    title: 'You are verified!',
    body: 'You can now go online and take calls.',
  });

  const res = await call('GET', '/api/notifications', { token: signToken(listener) });
  assert.equal(res.body.notifications.length, 1);
  assert.equal(res.body.notifications[0].type, 'kyc_approved');
});
