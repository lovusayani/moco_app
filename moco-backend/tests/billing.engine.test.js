'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const billing = require('../src/modules/calls/billing.engine');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const {
  createUser,
  createActiveCall,
  balanceOf,
  earningsOf,
  tickCount,
  resetDb,
} = require('./helpers');
const { CALL_END_REASON, CALL_STATUS } = require('../src/utils/constants');
const { query } = db;

test.before(async () => {
  await resetDb();
});

test.after(async () => {
  await db.close();
  await redisConfig.close();
});

test('preflight rejects a caller who cannot fund one full minute', async () => {
  await resetDb();
  const caller = await createUser({ balance: 5 });
  // The free-trial flag would otherwise let them through regardless.
  await query('UPDATE users SET free_trial_used = TRUE WHERE id = $1', [caller.id]);

  const audio = await billing.preflight({ callerId: caller.id, callType: 'audio' });
  assert.equal(audio.ok, false);
  assert.equal(audio.reason, 'insufficient_balance');

  await query('UPDATE wallets SET coin_balance = 6 WHERE user_id = $1', [caller.id]);
  const retry = await billing.preflight({ callerId: caller.id, callType: 'audio' });
  assert.equal(retry.ok, true);

  // 6 coins funds audio but not video, which costs 12.
  const video = await billing.preflight({ callerId: caller.id, callType: 'video' });
  assert.equal(video.ok, false);
});

test('preflight lets a first-time caller through on the free trial', async () => {
  await resetDb();
  const caller = await createUser({ balance: 0 });
  const result = await billing.preflight({ callerId: caller.id, callType: 'video' });
  assert.equal(result.ok, true);
  assert.equal(result.freeSeconds, 60);
});

test('a tick debits the caller, credits the listener, and splits the platform share', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const listener = await createUser({ listener: true });
  const call = await createActiveCall({ caller, listener, type: 'audio' });
  await billing.initCallState(call, 100);

  const result = await billing.settleTick({ callId: call.id, minuteIndex: 1 });

  assert.equal(result.status, 'billed');
  assert.equal(result.rate, 6);
  assert.equal(result.listenerShare, 2);
  assert.equal(result.platformShare, 4);
  assert.equal(await balanceOf(caller.id), 94);
  assert.equal(await earningsOf(listener.id), 2);

  const { rows } = await query('SELECT * FROM call_ticks WHERE call_id = $1', [call.id]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].coins_debited, 6);
  assert.equal(rows[0].listener_share + rows[0].platform_share, rows[0].coins_debited);
});

test('video bills at 12 with a 4-coin listener share', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const listener = await createUser({ listener: true });
  const call = await createActiveCall({ caller, listener, type: 'video' });
  await billing.initCallState(call, 100);

  const result = await billing.settleTick({ callId: call.id, minuteIndex: 1 });
  assert.equal(result.status, 'billed');
  assert.equal(await balanceOf(caller.id), 88);
  assert.equal(await earningsOf(listener.id), 4);
});

test('a replayed tick for the same minute cannot bill twice', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const listener = await createUser({ listener: true });
  const call = await createActiveCall({ caller, listener });
  await billing.initCallState(call, 100);

  const first = await billing.settleTick({ callId: call.id, minuteIndex: 1 });
  const replay = await billing.settleTick({ callId: call.id, minuteIndex: 1 });

  assert.equal(first.status, 'billed');
  assert.equal(replay.status, 'duplicate');
  // The replay must have rolled back its debit entirely, not just skipped the row.
  assert.equal(await balanceOf(caller.id), 94);
  assert.equal(await tickCount(call.id), 1);
});

test('concurrent ticks for one minute bill exactly once', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const listener = await createUser({ listener: true });
  const call = await createActiveCall({ caller, listener });
  await billing.initCallState(call, 100);

  // Fire ten ticks for the same minute at once: the lock stops most, and the
  // UNIQUE constraint stops whatever slips past it.
  const results = await Promise.all(
    Array.from({ length: 10 }, () => billing.settleTick({ callId: call.id, minuteIndex: 3 })),
  );

  const billed = results.filter((r) => r.status === 'billed');
  assert.equal(billed.length, 1, 'exactly one tick should bill');
  assert.equal(await balanceOf(caller.id), 94);
  assert.equal(await earningsOf(listener.id), 2);
  assert.equal(await tickCount(call.id), 1);
});

test('billing stops at insufficient balance instead of overdrawing', async () => {
  await resetDb();
  // Exactly two audio minutes of runway.
  const caller = await createUser({ balance: 12 });
  const listener = await createUser({ listener: true });
  const call = await createActiveCall({ caller, listener });
  await billing.initCallState(call, 12);

  assert.equal((await billing.settleTick({ callId: call.id, minuteIndex: 1 })).status, 'billed');
  const second = await billing.settleTick({ callId: call.id, minuteIndex: 2 });
  assert.equal(second.status, 'billed');
  assert.equal(second.minutesRemaining, 0);
  assert.equal(second.lowBalance, true, 'the client must get its recharge warning');

  const third = await billing.settleTick({ callId: call.id, minuteIndex: 3 });
  assert.equal(third.status, 'insufficient_balance');
  assert.equal(await balanceOf(caller.id), 0, 'balance must never go negative');
  assert.equal(await tickCount(call.id), 2, 'the failed minute must leave no tick row');
});

test('the low-balance warning fires with a minute of runway left', async () => {
  await resetDb();
  const caller = await createUser({ balance: 18 });
  const listener = await createUser({ listener: true });
  const call = await createActiveCall({ caller, listener });
  await billing.initCallState(call, 18);

  const first = await billing.settleTick({ callId: call.id, minuteIndex: 1 });
  assert.equal(first.minutesRemaining, 2);
  assert.equal(first.lowBalance, false);

  const second = await billing.settleTick({ callId: call.id, minuteIndex: 2 });
  assert.equal(second.minutesRemaining, 1);
  assert.equal(second.lowBalance, true);
});

test('ending a call settles once and is safe to repeat', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const listener = await createUser({ listener: true });
  const call = await createActiveCall({ caller, listener });
  await billing.initCallState(call, 100);
  await query('UPDATE listener_profiles SET is_busy = TRUE WHERE user_id = $1', [listener.id]);

  await billing.settleTick({ callId: call.id, minuteIndex: 1 });

  const first = await billing.endCall({ callId: call.id, reason: CALL_END_REASON.CALLER_HANGUP });
  assert.equal(first.alreadyEnded, false);
  assert.equal(first.status, CALL_STATUS.ENDED);
  assert.equal(first.coins_spent, 6);
  assert.equal(first.listener_earned, 2);

  const second = await billing.endCall({ callId: call.id, reason: CALL_END_REASON.DISCONNECT });
  assert.equal(second.alreadyEnded, true, 'a second end must not re-settle');
  assert.equal(second.end_reason, CALL_END_REASON.CALLER_HANGUP, 'the first reason must stand');

  const { rows } = await query('SELECT is_busy FROM listener_profiles WHERE user_id = $1', [
    listener.id,
  ]);
  assert.equal(rows[0].is_busy, false, 'the listener must be freed for the next caller');

  // Live state must be gone so the sweeper does not revisit the call.
  assert.equal(await billing.getCallState(call.id), null);
});

test('a tick on an ended call does not bill', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const listener = await createUser({ listener: true });
  const call = await createActiveCall({ caller, listener });
  await billing.initCallState(call, 100);
  await billing.endCall({ callId: call.id, reason: CALL_END_REASON.CALLER_HANGUP });

  const result = await billing.settleTick({ callId: call.id, minuteIndex: 1 });
  assert.equal(result.status, 'not_active');
  assert.equal(await balanceOf(caller.id), 100);
});

test('the ledger reconstructs the wallet balance exactly', async () => {
  await resetDb();
  const caller = await createUser({ balance: 50 });
  const listener = await createUser({ listener: true });
  const call = await createActiveCall({ caller, listener });
  await billing.initCallState(call, 50);

  for (let minute = 1; minute <= 4; minute += 1) {
    await billing.settleTick({ callId: call.id, minuteIndex: minute });
  }

  const { rows } = await query(
    `SELECT COALESCE(SUM(delta), 0)::bigint AS total FROM coin_ledger WHERE user_id = $1`,
    [caller.id],
  );
  assert.equal(rows[0].total, await balanceOf(caller.id));
  assert.equal(await balanceOf(caller.id), 50 - 24);
});

test('the sweeper ends calls that stopped ticking', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const listener = await createUser({ listener: true });
  const call = await createActiveCall({ caller, listener });
  // No Redis state and an old started_at: the client died without hanging up.
  await query(`UPDATE calls SET started_at = now() - interval '10 minutes' WHERE id = $1`, [
    call.id,
  ]);

  const swept = await billing.sweepStaleCalls();
  assert.equal(swept.length, 1);
  assert.equal(swept[0].reason, CALL_END_REASON.DISCONNECT);

  const { rows } = await query('SELECT status FROM calls WHERE id = $1', [call.id]);
  assert.equal(rows[0].status, CALL_STATUS.ENDED);
});

test('the sweeper leaves a genuinely live call alone', async () => {
  await resetDb();
  const caller = await createUser({ balance: 100 });
  const listener = await createUser({ listener: true });
  const call = await createActiveCall({ caller, listener });
  await billing.initCallState(call, 100);
  await query(`UPDATE calls SET started_at = now() - interval '10 minutes' WHERE id = $1`, [
    call.id,
  ]);

  const swept = await billing.sweepStaleCalls();
  assert.equal(swept.length, 0, 'a call with fresh tick state is still live');
});
