'use strict';

/**
 * Safety guard for the unit/integration suite.
 *
 * The suite TRUNCATEs tables and FLUSHDBs Redis between tests. It must only
 * ever run against a disposable local database and Redis (the ones in
 * docker-compose.yml) — never the shared Supabase/Upstash dev environment,
 * which it would wipe.
 *
 * Required by tests/helpers.js before anything connects, so every test file
 * that can reset data is covered. Override is deliberately awkward:
 * MOCO_ALLOW_DESTRUCTIVE_TESTS=yes-wipe-this-database.
 */

require('dotenv').config();

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1', 'postgres', 'redis']);

function dbHost() {
  if (process.env.DATABASE_URL) {
    try {
      return new URL(process.env.DATABASE_URL).hostname;
    } catch {
      return '(unparseable DATABASE_URL)';
    }
  }
  return process.env.PGHOST || '127.0.0.1';
}

function redisHost() {
  if (process.env.REDIS_URL) {
    try {
      return new URL(process.env.REDIS_URL).hostname;
    } catch {
      return '(unparseable REDIS_URL)';
    }
  }
  return process.env.REDIS_HOST || '127.0.0.1';
}

const override = process.env.MOCO_ALLOW_DESTRUCTIVE_TESTS === 'yes-wipe-this-database';
const db = dbHost();
const redis = redisHost();

if (!override && (!LOCAL_HOSTS.has(db) || !LOCAL_HOSTS.has(redis))) {
  // eslint-disable-next-line no-console
  console.error(
    '\nREFUSING TO RUN TESTS: they truncate every table and flush Redis.\n' +
      `  database host: ${db}\n  redis host:    ${redis}\n` +
      'Point DATABASE_URL/REDIS at the local docker-compose services (localhost) first.\n' +
      'Use `npm run smoke` to test against the shared dev environment — it is non-destructive.\n',
  );
  process.exit(1);
}
