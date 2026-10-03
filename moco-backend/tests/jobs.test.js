'use strict';

/**
 * The background-job layer that replaced BullMQ (src/jobs). Runs in `record`
 * mode (the test default), so nothing is published and no database is needed.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const jobs = require('../src/jobs');
const env = require('../src/config/env');

test.beforeEach(() => jobs.clearRecordedJobs());

test.after(async () => {
  await require('../src/config/db').close().catch(() => {});
  require('../src/config/redis').redis.disconnect();
});

test('the suite runs jobs in record mode', () => {
  assert.equal(env.jobs.mode, 'record');
});

test('a billing tick is keyed by call and minute, so a re-send collapses', async () => {
  await jobs.scheduleTick(42, 3, 60);
  const [job] = jobs.recordedJobs();
  assert.equal(job.topic, jobs.TOPICS.TICK);
  assert.deepEqual(job.payload, { callId: '42', minuteIndex: 3 });
  assert.equal(job.delaySeconds, 60);
  assert.equal(job.idempotencyKey, 'tick-42-3');
});

test('sweeps scheduled within the same minute share one idempotency key', async () => {
  await jobs.ensureSweep(60);
  await jobs.ensureSweep(60);
  const [a, b] = jobs.recordedJobs();
  assert.equal(a.topic, jobs.TOPICS.SWEEP);
  assert.match(a.idempotencyKey, /^sweep-\d+$/);
  // Either the same bucket, or (rarely) the minute rolled over between calls.
  const diff = Number(b.idempotencyKey.slice(6)) - Number(a.idempotencyKey.slice(6));
  assert.ok(diff === 0 || diff === 1);
});

test('a payout is published once per payout id', async () => {
  await jobs.processPayout(7);
  const [job] = jobs.recordedJobs();
  assert.equal(job.topic, jobs.TOPICS.PAYOUT);
  assert.deepEqual(job.payload, { payoutId: 7 });
  assert.equal(job.idempotencyKey, 'payout-7');
});

test('notifications carry their payload through unchanged', async () => {
  const payload = { userId: 5, title: 't', body: 'b', data: { a: '1' }, highPriority: true };
  await jobs.sendNotification(payload);
  assert.deepEqual(jobs.recordedJobs()[0].payload, payload);
});

test('every topic has a registered handler function', () => {
  // eslint-disable-next-line global-require
  const handlers = require('../src/jobs/handlers');
  for (const topic of Object.values(jobs.TOPICS)) {
    assert.equal(typeof handlers.resolveHandler(topic), 'function', topic);
  }
  assert.throws(() => handlers.resolveHandler('nope'), /no handler for topic/);
});
