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
   * WhatsApp Cloud API (Meta) — the FALLBACK OTP channel when an SMS does not
   * arrive. Sends an approved Authentication template only; never free-form
   * text. Every value is backend-only (moco-api), never sent to a client or
   * logged. All unset is a valid "WhatsApp fallback unavailable" state.
   */
  whatsapp: {
    accessToken: optional('WHATSAPP_ACCESS_TOKEN', ''),
    phoneNumberId: optional('WHATSAPP_PHONE_NUMBER_ID', ''),
    businessAccountId: optional('WHATSAPP_BUSINESS_ACCOUNT_ID', ''),
    templateName: optional('WHATSAPP_OTP_TEMPLATE_NAME', ''),
    templateLanguage: optional('WHATSAPP_OTP_TEMPLATE_LANGUAGE', 'en'),
    // Authentication templates carry a "Copy code"/one-tap button whose
    // parameter is the code itself; set false only for a template without one.
    templateHasCodeButton: bool('WHATSAPP_OTP_TEMPLATE_HAS_BUTTON', true),
    graphVersion: optional('WHATSAPP_GRAPH_VERSION', 'v23.0'),
    // Webhook (delivery status callbacks): verification token for Meta's
    // GET handshake, and the app secret that signs every POST.
    webhookVerifyToken: optional('WHATSAPP_WEBHOOK_VERIFY_TOKEN', ''),
    appSecret: optional('WHATSAPP_APP_SECRET', ''),
    // Outside production only: print the code instead of sending, like
    // SMS_PROVIDER=log. Ignored in production, where OTPs are never logged.
    devLog: !isProduction && bool('WHATSAPP_DEV_LOG', false),
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
    // Minimum gap between two code sends to one phone, on any channel.
    resendCooldownSeconds: int('OTP_RESEND_COOLDOWN', 30),
    // All channels together, per phone per hour (the original limit).
    maxRequestsPerHour: int('OTP_MAX_REQUESTS_PER_HOUR', 5),
    // WhatsApp sends cost money and reach a personal inbox: a tighter cap.
    maxWhatsappPerHour: int('OTP_MAX_WHATSAPP_PER_HOUR', 3),
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
