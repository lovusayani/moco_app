'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const { redis } = require('../src/config/redis');
const callEvents = require('../src/realtime/call.events');
const presence = require('../src/realtime/presence');
const { resetDb, createUser } = require('./helpers');
const { WS_EVENTS } = require('../src/utils/constants');

test.after(async () => {
  await db.close();
  await redisConfig.close();
});

/**
 * Captures what the workers publish on the Redis bridge.
 *
 * A subscriber connection cannot run ordinary commands, so this takes its own.
 */
async function captureEvents(run, { timeoutMs = 700 } = {}) {
  const subscriber = redisConfig.createQueueConnection();
  const received = [];

  await subscriber.subscribe(callEvents.CHANNEL);
  subscriber.on('message', (_channel, raw) => received.push(JSON.parse(raw)));

  // Let the subscription settle before triggering.
  await new Promise((r) => setTimeout(r, 120));
  await run();
  await new Promise((r) => setTimeout(r, timeoutMs));

  await subscriber.quit();
  return received;
}

test('going online broadcasts a presence event', async () => {
  await resetDb();
  const listener = await createUser({ listener: true });

  const events = await captureEvents(() => presence.setOnline(listener.id, true));
  const found = events.find((e) => e.event === WS_EVENTS.PRESENCE);

  assert.ok(found, 'a presence event should be published');
  assert.equal(found.broadcast, true, 'presence has no single recipient');
  assert.equal(found.payload.listenerId, Number(listener.id));
  assert.equal(found.payload.isOnline, true);
});

test('going offline broadcasts too', async () => {
  await resetDb();
  const listener = await createUser({ listener: true });
  await presence.setOnline(listener.id, true);

  const events = await captureEvents(() => presence.setOnline(listener.id, false));
  const found = events.find((e) => e.event === WS_EVENTS.PRESENCE);

  assert.ok(found);
  assert.equal(found.payload.isOnline, false);
});

test('the presence event carries busy state, so a card can distinguish it', async () => {
  await resetDb();
  const listener = await createUser({ listener: true });
  await db.query('UPDATE listener_profiles SET is_busy = TRUE WHERE user_id = $1', [
    listener.id,
  ]);

  const events = await captureEvents(() => presence.setOnline(listener.id, true));
  const found = events.find((e) => e.event === WS_EVENTS.PRESENCE);

  assert.equal(found.payload.isBusy, true);
});

test('presence still updates the database and Redis key', async () => {
  await resetDb();
  const listener = await createUser({ listener: true });

  await presence.setOnline(listener.id, true);
  const { rows } = await db.query(
    'SELECT is_online FROM listener_profiles WHERE user_id = $1',
    [listener.id],
  );
  assert.equal(rows[0].is_online, true);
  assert.equal(await presence.isConnected(listener.id), true);

  await presence.setOnline(listener.id, false);
  assert.equal(await presence.isConnected(listener.id), false);
});

test('a broadcast is distinguishable from a user-targeted event', async () => {
  await resetDb();
  const user = await createUser();

  const events = await captureEvents(async () => {
    await callEvents.publishBroadcast('test:broadcast', { hello: true });
    await callEvents.publishToUser(user.id, 'test:targeted', { hello: true });
  });

  const broadcast = events.find((e) => e.event === 'test:broadcast');
  const targeted = events.find((e) => e.event === 'test:targeted');

  assert.equal(broadcast.broadcast, true);
  assert.equal(broadcast.userId, undefined);
  // A targeted event still names its recipient.
  assert.equal(targeted.userId, String(user.id));
  assert.notEqual(targeted.broadcast, true);
});
