'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const c = require('../src/utils/constants');

/**
 * These assert the economy from the project summary. If a rate is ever changed
 * these tests should fail loudly — they are the tripwire on the business model,
 * not a restatement of the implementation.
 */

test('audio bills 6 coins with 2 to the listener', () => {
  assert.equal(c.coinsPerMinute('audio'), 6);
  assert.equal(c.listenerSharePerMinute('audio'), 2);
  assert.equal(c.platformSharePerMinute('audio'), 4);
});

test('video bills 12 coins with 4 to the listener', () => {
  assert.equal(c.coinsPerMinute('video'), 12);
  assert.equal(c.listenerSharePerMinute('video'), 4);
  assert.equal(c.platformSharePerMinute('video'), 8);
});

test('the listener share is a third of gross on both call types', () => {
  for (const type of ['audio', 'video']) {
    const rate = c.rateFor(type);
    assert.equal(rate.listenerCoinsPerMinute * 3, rate.coinsPerMinute);
  }
});

test('an unknown call type throws rather than defaulting to a rate', () => {
  assert.throws(() => c.coinsPerMinute('hologram'), /Unknown call type/);
});

test('coin packs match the published price list', () => {
  assert.deepEqual(
    c.COIN_PACKS.map((p) => [p.priceInr, p.coins, p.bonus]),
    [
      [49, 49, 0],
      [99, 99, 5],
      [299, 299, 25],
      [599, 599, 75],
      [999, 999, 150],
    ],
  );
});

test('bonuses only ever increase the coins received', () => {
  for (const pack of c.COIN_PACKS) {
    assert.ok(c.packTotalCoins(pack) >= pack.priceInr, `${pack.id} must not short the buyer`);
  }
});

test('affordability is whole minutes only, never partial', () => {
  assert.equal(c.minutesAffordable(45, 'audio'), 7);
  assert.equal(c.minutesAffordable(45, 'video'), 3);
  assert.equal(c.minutesAffordable(5, 'audio'), 0);
  assert.equal(c.canAffordCall(5, 'audio'), false);
  assert.equal(c.canAffordCall(6, 'audio'), true);
  assert.equal(c.canAffordCall(11, 'video'), false);
  assert.equal(c.canAffordCall(12, 'video'), true);
});

test('the design sample balances buy the expected minutes', () => {
  // The balances shown in the Claude Design wallet screens.
  assert.deepEqual(
    [45, 120, 350, 890].map((b) => c.minutesAffordable(b, 'audio')),
    [7, 20, 58, 148],
  );
});

test('the free trial is 60 seconds and ticks are 60 seconds', () => {
  assert.equal(c.FREE_TRIAL_SECONDS, 60);
  assert.equal(c.TICK_INTERVAL_SECONDS, 60);
});

test('constants are frozen so nothing can mutate a rate at runtime', () => {
  assert.throws(() => {
    'use strict';
    c.RATES.audio.coinsPerMinute = 1;
  });
});

test('bullmq queue names avoid the colon separator bullmq reserves', () => {
  for (const name of Object.values(c.BULL_QUEUES)) {
    assert.ok(!name.includes(':'), `${name} must not contain ':'`);
  }
});
