'use strict';

require('dotenv').config();

/**
 * Env access is centralised here so every host/port is a config change rather
 * than a code change. Production runs on Vercel (project moco-api) against
 * managed Postgres (Supabase) and Redis (Upstash); see docs/DEPLOYMENT-VERCEL.md.
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
const onVercel = Boolean(process.env.VERCEL);

function list(name, fallback) {
  const raw = optional(name, undefined);
  if (raw === undefined) return fallback;
  return raw
    .split(',')
    .map((v) => v.trim())
    .filter(Boolean);
}

const env = {
  nodeEnv,
  isProduction,
  isTest,
  onVercel,
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
    // Supabase requires TLS; the local Docker Postgres does not.
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

  /**
   * Sign-in code delivery channels (src/modules/auth/otp/). A channel is
   * offered to users only when its provider is configured; 'log' providers
   * (which print the code) exist for local development and never run in
   * production. Every secret here is backend-only.
   */
  email: {
    // 'resend' (production) | 'log' (development).
    provider: optional('EMAIL_PROVIDER', isProduction ? 'resend' : 'log'),
    from: optional('EMAIL_FROM', ''),
    resendApiKey: optional('RESEND_API_KEY', ''),
  },

  whatsapp: {
    // WhatsApp Cloud API with an approved Authentication template.
    accessToken: optional('WHATSAPP_ACCESS_TOKEN', ''),
    phoneNumberId: optional('WHATSAPP_PHONE_NUMBER_ID', ''),
    templateName: optional('WHATSAPP_OTP_TEMPLATE', ''),
    templateLanguage: optional('WHATSAPP_OTP_TEMPLATE_LANGUAGE', 'en'),
    graphVersion: optional('WHATSAPP_GRAPH_VERSION', 'v21.0'),
  },

  telegram: {
    // Telegram Gateway API (gatewayapi.telegram.org): delivers a code to the
    // Telegram account registered to a phone number. No bot linking needed.
    gatewayToken: optional('TELEGRAM_GATEWAY_TOKEN', ''),
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

  // Google Play Billing purchase verification (Play Store builds only). Both
  // unset is a valid, honest "not configured" state — see
  // src/integrations/google_play.js — not a boot-time failure, mirroring how
  // Supabase Storage and FCM are handled: this backend must run without a
  // Play Console account during development and CI.
  googlePlay: {
    packageName: optional('GOOGLE_PLAY_PACKAGE_NAME', ''),
    // The service account's JSON key, as a single-line string (its own
    // private key PEM included). Never logged, never returned by any route.
    serviceAccountJson: optional('GOOGLE_PLAY_SERVICE_ACCOUNT_JSON', ''),
  },

  /**
   * Browser origins allowed to call the API and open a socket. The web app,
   * the admin console and the API are separate origins in production, so
   * this is an explicit allow-list (never "*"). Requests with no Origin
   * header (the Android app, webhooks, curl) are not browser requests and are
   * unaffected. Outside production, localhost on any port is also allowed.
   */
  cors: {
    origins: list('CORS_ORIGINS', []),
  },

  /** Background jobs — see src/jobs/index.js. */
  jobs: {
    mode: optional('JOBS_MODE', onVercel ? 'vercel' : isTest ? 'record' : 'inline'),
  },

  otp: {
    // In non-production the OTP is fixed so QA and the emulator can log in.
    fixedCode: isProduction ? null : optional('OTP_FIXED_CODE', '123456'),
    ttlSeconds: int('OTP_TTL', 300),
    maxAttempts: int('OTP_MAX_ATTEMPTS', 5),
    // Minimum gap between two codes to the same email/phone.
    resendCooldownSeconds: int('OTP_RESEND_COOLDOWN', 30),
    // Codes per email/phone per hour, across all channels.
    maxSendsPerHour: int('OTP_MAX_SENDS_PER_HOUR', 5),
  },

  // Storage only — the same Supabase project used for Postgres, or a separate
  // one, doesn't matter here. The service-role key is backend-only and never
  // reaches Flutter; it exists to mint short-lived signed upload/view URLs.
  // Both unset is a valid, honest "photo messages unavailable" state — see
  // src/integrations/chat.storage.js — not a boot-time failure, since this
  // backend must run without it during local dev before the bucket exists.
  supabaseStorage: {
    url: optional('SUPABASE_URL', ''),
    serviceRoleKey: optional('SUPABASE_SERVICE_ROLE_KEY', ''),
  },
};

module.exports = env;
