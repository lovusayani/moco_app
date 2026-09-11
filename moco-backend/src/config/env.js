'use strict';

require('dotenv').config();

/**
 * Env access is centralised here so every host/port is a config change rather
 * than a code change — this is what makes the planned split of Postgres and
 * Redis onto DigitalOcean managed add-ons a config-only migration.
 */

function required(name) {
  const value = process.env[name];
  if (value === undefined || value === '') {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function optional(name, fallback) {
  const value = process.env[name];
  return value === undefined || value === '' ? fallback : value;
}

function int(name, fallback) {
  const raw = optional(name, undefined);
  if (raw === undefined) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (Number.isNaN(parsed)) throw new Error(`Environment variable ${name} must be an integer`);
  return parsed;
}

function bool(name, fallback) {
  const raw = optional(name, undefined);
  if (raw === undefined) return fallback;
  return raw === 'true' || raw === '1';
}

const nodeEnv = optional('NODE_ENV', 'development');
const isProduction = nodeEnv === 'production';
const isTest = nodeEnv === 'test';

const env = {
  nodeEnv,
  isProduction,
  isTest,
  port: int('PORT', 3000),
  logLevel: optional('LOG_LEVEL', isProduction ? 'info' : 'debug'),

  db: {
    // When set (e.g. a Supabase session-pooler or direct-connection URI), this
    // takes over from the discrete PG* fields below entirely — see db.js.
    // Prefer Supabase's SESSION pooler or a direct connection, not the
    // transaction pooler: withTransaction() holds one BEGIN..COMMIT open on a
    // single checked-out client, which the transaction pooler does not
    // reliably support alongside node-pg's parameterized (extended-protocol)
    // queries.
    connectionString: optional('DATABASE_URL', undefined),
    host: optional('PGHOST', '127.0.0.1'),
    port: int('PGPORT', 5432),
    user: optional('PGUSER', 'moco'),
    password: optional('PGPASSWORD', 'moco'),
    database: optional('PGDATABASE', isTest ? 'moco_test' : 'moco'),
    // DO managed Postgres and Supabase both require TLS; a local droplet- or
    // Docker-resident Postgres does not.
    ssl: bool('PGSSL', false) ? { rejectUnauthorized: false } : false,
    poolMax: int('PG_POOL_MAX', 10),
  },

  redis: {
    host: optional('REDIS_HOST', '127.0.0.1'),
    port: int('REDIS_PORT', 6379),
    password: optional('REDIS_PASSWORD', undefined),
    tls: bool('REDIS_TLS', false) ? {} : undefined,
    db: int('REDIS_DB', isTest ? 1 : 0),
  },

  jwt: {
    // Never allow the dev fallback to reach production.
    secret: isProduction ? required('JWT_SECRET') : optional('JWT_SECRET', 'dev-secret-change-me'),
    accessTtl: optional('JWT_ACCESS_TTL', '30d'),
  },

  agora: {
    appId: optional('AGORA_APP_ID', ''),
    appCertificate: optional('AGORA_APP_CERTIFICATE', ''),
    tokenTtlSeconds: int('AGORA_TOKEN_TTL', 3600),
    // Agora signs its webhook payloads; we verify before acting on them.
    webhookSecret: optional('AGORA_WEBHOOK_SECRET', ''),
  },

  sms: {
    provider: optional('SMS_PROVIDER', 'log'),
    apiKey: optional('SMS_API_KEY', ''),
    senderId: optional('SMS_SENDER_ID', 'MOCOAP'),
  },

  fcm: {
    serverKey: optional('FCM_SERVER_KEY', ''),
  },

  payments: {
    provider: optional('PAYMENT_PROVIDER', 'mock'),
    keyId: optional('PAYMENT_KEY_ID', ''),
    keySecret: optional('PAYMENT_KEY_SECRET', ''),
    webhookSecret: optional('PAYMENT_WEBHOOK_SECRET', ''),
  },

  otp: {
    // In non-production the OTP is fixed so QA and the emulator can log in.
    fixedCode: isProduction ? null : optional('OTP_FIXED_CODE', '123456'),
    ttlSeconds: int('OTP_TTL', 300),
    maxAttempts: int('OTP_MAX_ATTEMPTS', 5),
  },
};

module.exports = env;
