'use strict';

const { Pool } = require('pg');
const env = require('./env');
const logger = require('../utils/logger');

/**
 * Postgres access. Coin amounts are BIGINT columns; node-pg hands BIGINT back
 * as a string by default, which would silently turn arithmetic into string
 * concatenation. Parse OID 20 (int8) into a Number — coin balances are far
 * below Number.MAX_SAFE_INTEGER, so this is safe and removes a whole class of
 * bug from the billing path.
 */
require('pg').types.setTypeParser(20, (value) => Number.parseInt(value, 10));

/**
 * DATABASE_URL (e.g. Supabase's session pooler or a direct connection) wins
 * over the discrete PG* fields when set, so a hosted database is a pure env
 * change — see the comment on env.db.connectionString for why it must be the
 * session pooler, not the transaction pooler.
 */
const pool = new Pool(
  env.db.connectionString
    ? {
        connectionString: env.db.connectionString,
        ssl: env.db.ssl,
        max: env.db.poolMax,
        idleTimeoutMillis: 30_000,
        connectionTimeoutMillis: 5_000,
      }
    : {
        host: env.db.host,
        port: env.db.port,
        user: env.db.user,
        password: env.db.password,
        database: env.db.database,
        ssl: env.db.ssl,
        max: env.db.poolMax,
        idleTimeoutMillis: 30_000,
        connectionTimeoutMillis: 5_000,
      },
);

pool.on('error', (err) => {
  logger.error({ err }, 'idle postgres client error');
});

/** Run a single query on a pooled connection. */
function query(text, params) {
  return pool.query(text, params);
}

/**
 * Run `fn` inside a transaction, committing on success and rolling back on any
 * throw. Every money-moving operation goes through this — a wallet balance is
 * never written outside a transaction that also writes its ledger row.
 */
async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (rollbackErr) {
      logger.error({ err: rollbackErr }, 'rollback failed');
    }
    throw err;
  } finally {
    client.release();
  }
}

async function close() {
  await pool.end();
}

module.exports = { pool, query, withTransaction, close };
