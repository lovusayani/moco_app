'use strict';

const fs = require('fs');
const path = require('path');
const { pool, close } = require('../config/db');
const logger = require('../utils/logger');

/**
 * Minimal forward-only migration runner. Each .sql file in migrations/ runs
 * once, inside a transaction, in filename order, and is recorded in
 * schema_migrations. Deliberately dependency-free: on a small droplet the
 * fewer moving parts in the deploy path, the better.
 */

const MIGRATIONS_DIR = path.join(__dirname, 'migrations');

async function ensureMigrationsTable(client) {
  await client.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      name       TEXT PRIMARY KEY,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )`);
}

function migrationFiles() {
  return fs
    .readdirSync(MIGRATIONS_DIR)
    .filter((name) => name.endsWith('.sql') && !name.endsWith('.down.sql'))
    .sort();
}

async function up() {
  const client = await pool.connect();
  try {
    await ensureMigrationsTable(client);
    const { rows } = await client.query('SELECT name FROM schema_migrations');
    const applied = new Set(rows.map((row) => row.name));

    const pending = migrationFiles().filter((name) => !applied.has(name));
    if (pending.length === 0) {
      logger.info('no pending migrations');
      return;
    }

    for (const name of pending) {
      const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, name), 'utf8');
      // One transaction per migration: a failure leaves the schema at the last
      // fully applied migration rather than half-way through this one.
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query('INSERT INTO schema_migrations (name) VALUES ($1)', [name]);
        await client.query('COMMIT');
        logger.info({ migration: name }, 'applied migration');
      } catch (err) {
        await client.query('ROLLBACK');
        logger.error({ migration: name, err }, 'migration failed');
        throw err;
      }
    }
  } finally {
    client.release();
  }
}

/**
 * Rolls back the most recent migration, if it ships a matching `.down.sql`.
 * Intended for local iteration — production rolls forward.
 */
async function down() {
  const client = await pool.connect();
  try {
    await ensureMigrationsTable(client);
    const { rows } = await client.query(
      'SELECT name FROM schema_migrations ORDER BY name DESC LIMIT 1',
    );
    if (rows.length === 0) {
      logger.info('nothing to roll back');
      return;
    }
    const name = rows[0].name;
    const downFile = path.join(MIGRATIONS_DIR, name.replace(/\.sql$/, '.down.sql'));
    if (!fs.existsSync(downFile)) {
      throw new Error(`No down migration for ${name}`);
    }
    await client.query('BEGIN');
    try {
      await client.query(fs.readFileSync(downFile, 'utf8'));
      await client.query('DELETE FROM schema_migrations WHERE name = $1', [name]);
      await client.query('COMMIT');
      logger.info({ migration: name }, 'rolled back migration');
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    }
  } finally {
    client.release();
  }
}

async function main() {
  const command = process.argv[2] || 'up';
  if (command === 'up') await up();
  else if (command === 'down') await down();
  else throw new Error(`Unknown command: ${command}`);
  await close();
}

if (require.main === module) {
  main().catch((err) => {
    logger.error({ err }, 'migration run failed');
    process.exit(1);
  });
}

module.exports = { up, down };
