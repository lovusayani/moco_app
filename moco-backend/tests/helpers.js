'use strict';

const { query, withTransaction } = require('../src/config/db');
const { redis } = require('../src/config/redis');
const { CALL_STATUS, coinsPerMinute, listenerSharePerMinute } =
  require('../src/utils/constants');

let counter = 0;

/** Unique phone per created user so tests never collide on the phone UNIQUE index. */
function nextPhone() {
  counter += 1;
  return `+9198${String(Date.now()).slice(-6)}${String(counter).padStart(2, '0')}`;
}

async function createUser({ balance = 0, listener = false } = {}) {
  return withTransaction(async (client) => {
    const { rows } = await client.query(
      `INSERT INTO users (phone, display_name, role) VALUES ($1, $2, $3) RETURNING *`,
      [nextPhone(), listener ? 'Test Listener' : 'Test Caller', listener ? 'listener' : 'user'],
    );
    const user = rows[0];

    await client.query('INSERT INTO wallets (user_id, coin_balance) VALUES ($1, $2)', [
      user.id,
      balance,
    ]);

    if (balance > 0) {
      await client.query(
        `INSERT INTO coin_ledger (user_id, delta, reason, balance_after)
         VALUES ($1, $2, 'topup', $2)`,
        [user.id, balance],
      );
    }

    if (listener) {
      await client.query(
        `INSERT INTO listener_profiles (user_id, kyc_status, is_online)
         VALUES ($1, 'approved', TRUE)`,
        [user.id],
      );
    }

    return user;
  });
}

async function createActiveCall({ caller, listener, type = 'audio' }) {
  const { rows } = await query(
    `INSERT INTO calls (caller_id, listener_id, type, status, agora_channel,
                        rate_per_minute, listener_rate_per_minute, started_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, now())
     RETURNING *`,
    [
      caller.id,
      listener.id,
      type,
      CALL_STATUS.ACTIVE,
      `ch_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
      coinsPerMinute(type),
      listenerSharePerMinute(type),
    ],
  );
  return rows[0];
}

const balanceOf = async (userId) =>
  (await query('SELECT coin_balance FROM wallets WHERE user_id = $1', [userId])).rows[0]
    ?.coin_balance ?? 0;

const earningsOf = async (userId) =>
  (await query('SELECT earnings_balance FROM listener_profiles WHERE user_id = $1', [userId]))
    .rows[0]?.earnings_balance ?? 0;

const ledgerCount = async (userId) =>
  Number(
    (await query('SELECT count(*)::int AS c FROM coin_ledger WHERE user_id = $1', [userId]))
      .rows[0].c,
  );

const tickCount = async (callId) =>
  Number(
    (await query('SELECT count(*)::int AS c FROM call_ticks WHERE call_id = $1', [callId]))
      .rows[0].c,
  );

/**
 * A feed post, inserted directly.
 *
 * Posts are created through the API only when Supabase Storage is configured
 * (the endpoint verifies the object actually exists in the bucket), so tests
 * that need existing posts seed them here instead. `mediaPath` mirrors the
 * real scheme — prefixed with the author's own id — because the ownership
 * checks under test are prefix checks on exactly that.
 */
async function createPost({ author, mediaType = 'image', caption = null, status = 'active' }) {
  const ext = mediaType === 'video' ? 'mp4' : 'jpg';
  const { rows } = await query(
    `INSERT INTO posts (author_user_id, media_type, media_path, caption, status)
     VALUES ($1, $2, $3, $4, $5) RETURNING *`,
    [
      author.id,
      mediaType,
      `${author.id}/${Date.now()}_${Math.random().toString(36).slice(2, 10)}.${ext}`,
      caption,
      status,
    ],
  );
  return rows[0];
}

async function resetDb() {
  await query(
    `TRUNCATE users, wallets, coin_ledger, listener_profiles, listener_earnings,
              calls, call_ticks, payouts, conversations, messages, message_reactions,
              posts, notifications, purchases, blocks, reports, call_ratings, auth_events
              RESTART IDENTITY CASCADE`,
  );
  await redis.flushdb();
}

module.exports = {
  createUser,
  createActiveCall,
  createPost,
  balanceOf,
  earningsOf,
  ledgerCount,
  tickCount,
  resetDb,
  nextPhone,
};
