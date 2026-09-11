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

test('sending a message creates the conversation and appears in the recipient list', async () => {
  await resetDb();
  const a = await createUser();
  const b = await createUser();

  const send = await call('POST', `/api/chat/${b.id}/messages`, {
    token: signToken(a),
    body: { body: 'hi there' },
  });
  assert.equal(send.status, 201);
  assert.equal(send.body.message.type, 'text');
  assert.equal(send.body.message.body, 'hi there');
  assert.deepEqual(send.body.message.reactions, []);

  const list = await call('GET', '/api/chat', { token: signToken(b) });
  assert.equal(list.status, 200);
  assert.equal(list.body.conversations.length, 1);
  assert.equal(list.body.conversations[0].counterparty.id, a.id);
  assert.equal(list.body.conversations[0].lastMessage, 'hi there');
  assert.equal(list.body.conversations[0].unreadCount, 1);
});

test('a blocked user cannot be messaged in either direction', async () => {
  await resetDb();
  const a = await createUser();
  const b = await createUser();
  await db.query('INSERT INTO blocks (blocker_id, blocked_id) VALUES ($1, $2)', [a.id, b.id]);

  const fromBlocker = await call('POST', `/api/chat/${b.id}/messages`, {
    token: signToken(a),
    body: { body: 'hello' },
  });
  assert.equal(fromBlocker.status, 403);

  const fromBlocked = await call('POST', `/api/chat/${a.id}/messages`, {
    token: signToken(b),
    body: { body: 'hello' },
  });
  assert.equal(fromBlocked.status, 403);
});

test('you cannot message yourself', async () => {
  await resetDb();
  const a = await createUser();
  const result = await call('POST', `/api/chat/${a.id}/messages`, {
    token: signToken(a),
    body: { body: 'talking to myself' },
  });
  assert.equal(result.status, 403);
});

test('fetching message history marks the other side\'s messages read', async () => {
  await resetDb();
  const a = await createUser();
  const b = await createUser();

  await call('POST', `/api/chat/${b.id}/messages`, {
    token: signToken(a),
    body: { body: 'first' },
  });
  await call('POST', `/api/chat/${b.id}/messages`, {
    token: signToken(a),
    body: { body: 'second' },
  });

  const before = await call('GET', '/api/chat', { token: signToken(b) });
  assert.equal(before.body.conversations[0].unreadCount, 2);

  const history = await call('GET', `/api/chat/${a.id}/messages`, { token: signToken(b) });
  assert.equal(history.status, 200);
  assert.equal(history.body.messages.length, 2);
  // Oldest first.
  assert.equal(history.body.messages[0].body, 'first');
  assert.equal(history.body.messages[1].body, 'second');

  const after = await call('GET', '/api/chat', { token: signToken(b) });
  assert.equal(after.body.conversations[0].unreadCount, 0);
});

test('an image message needs a mediaPath issued to the sender', async () => {
  await resetDb();
  const a = await createUser();
  const b = await createUser();

  const stolen = await call('POST', `/api/chat/${b.id}/messages`, {
    token: signToken(a),
    body: { type: 'image', mediaPath: `${b.id}/not-mine.jpg` },
  });
  assert.equal(stolen.status, 403);
});

test('photo upload authorization reports itself unavailable when storage is not configured', async () => {
  await resetDb();
  const a = await createUser();
  const result = await call('POST', '/api/chat/media/upload-url', {
    token: signToken(a),
    body: { mimeType: 'image/jpeg' },
  });
  // In the test environment SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY are unset,
  // so this must fail honestly rather than throw or fake a URL.
  assert.equal(result.status, 400);
  assert.equal(result.body.error.code, 'storage_not_configured');
});

test('reactions: add, change, and remove are all idempotent', async () => {
  await resetDb();
  const a = await createUser();
  const b = await createUser();

  const sent = await call('POST', `/api/chat/${b.id}/messages`, {
    token: signToken(a),
    body: { body: 'react to this' },
  });
  const messageId = sent.body.message.id;

  const react = await call('PUT', `/api/chat/messages/${messageId}/reaction`, {
    token: signToken(b),
    body: { emoji: '❤️' },
  });
  assert.equal(react.status, 200);
  assert.equal(react.body.emoji, '❤️');

  // Changing is the same idempotent PUT, not a second write path.
  const change = await call('PUT', `/api/chat/messages/${messageId}/reaction`, {
    token: signToken(b),
    body: { emoji: '😂' },
  });
  assert.equal(change.status, 200);

  const history = await call('GET', `/api/chat/${b.id}/messages`, { token: signToken(a) });
  const message = history.body.messages.find((m) => m.id === messageId);
  assert.equal(message.reactions.length, 1, 'changing a reaction must not add a second row');
  assert.equal(message.reactions[0].emoji, '😂');

  const remove = await call('DELETE', `/api/chat/messages/${messageId}/reaction`, {
    token: signToken(b),
  });
  assert.equal(remove.status, 200);

  const removeAgain = await call('DELETE', `/api/chat/messages/${messageId}/reaction`, {
    token: signToken(b),
  });
  assert.equal(removeAgain.status, 200, 'removing twice must not error');

  const after = await call('GET', `/api/chat/${b.id}/messages`, { token: signToken(a) });
  assert.deepEqual(after.body.messages.find((m) => m.id === messageId).reactions, []);
});

test('a stranger cannot react to a conversation they are not part of', async () => {
  await resetDb();
  const a = await createUser();
  const b = await createUser();
  const stranger = await createUser();

  const sent = await call('POST', `/api/chat/${b.id}/messages`, {
    token: signToken(a),
    body: { body: 'private' },
  });

  const result = await call('PUT', `/api/chat/messages/${sent.body.message.id}/reaction`, {
    token: signToken(stranger),
    body: { emoji: '👍' },
  });
  assert.equal(result.status, 403);
});
