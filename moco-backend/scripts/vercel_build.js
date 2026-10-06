'use strict';

/**
 * Vercel "Build Command" for the moco-api project (`npm run build:vercel`).
 *
 * The API has no compile step; its functions are api/*.mjs. This only:
 *   1. fails the deployment early if production configuration is missing,
 *      instead of every request failing later;
 *   2. writes the project's static output: a robots.txt and nothing else. The
 *      repo's public/ folder (the admin console's files) must not be served
 *      from the API domain — the console is its own project;
 *   3. records the migration file names in src/db/migrations.generated.json,
 *      which the admin health check require()s, so the list is bundled into
 *      the function (a directory read is not traced into the bundle).
 *
 * Checks names only; never prints a value.
 */

const fs = require('fs');
const path = require('path');

const isProductionDeploy = process.env.VERCEL_ENV === 'production';

const REQUIRED = [
  'NODE_ENV',
  'DATABASE_URL',
  'PGSSL',
  'REDIS_HOST',
  'REDIS_PORT',
  'REDIS_PASSWORD',
  'REDIS_TLS',
  'JWT_SECRET',
  'CORS_ORIGINS',
  'CRON_SECRET',
  'SUPABASE_URL',
  'SUPABASE_SERVICE_ROLE_KEY',
  'ADMIN_PHONES',
];

if (process.env.VERCEL) {
  const missing = REQUIRED.filter((name) => !(process.env[name] || '').trim());
  if (missing.length) {
    console.error(`[moco-api build] missing environment variables: ${missing.join(', ')}`);
    process.exit(1);
  }
  if (isProductionDeploy && process.env.NODE_ENV !== 'production') {
    console.error('[moco-api build] NODE_ENV must be "production" for the production deployment');
    process.exit(1);
  }
  for (const origin of process.env.CORS_ORIGINS.split(',').map((o) => o.trim())) {
    if (!/^https:\/\/[a-z0-9.-]+$/.test(origin)) {
      console.error(`[moco-api build] CORS_ORIGINS entry is not an https origin: ${origin}`);
      process.exit(1);
    }
  }
  // Email is the default sign-in method and must work in production. (SMS,
  // WhatsApp and Telegram are optional: unconfigured, they are simply not
  // offered, and the 'log' SMS provider is refused at runtime.)
  if (isProductionDeploy) {
    const provider = process.env.EMAIL_PROVIDER || 'resend';
    const missing = provider === 'resend' ? ['RESEND_API_KEY', 'EMAIL_FROM'].filter((n) => !(process.env[n] || '').trim()) : [];
    if (provider !== 'resend' || missing.length) {
      console.error(`[moco-api build] email sign-in is not configured for production (EMAIL_PROVIDER=${provider}${missing.length ? `, missing ${missing.join(', ')}` : ''})`);
      process.exit(1);
    }
  }
}

const out = path.join(__dirname, '..', 'vercel-static');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, 'robots.txt'), 'User-agent: *\nDisallow: /\n');
const migrationsDir = path.join(__dirname, '..', 'src', 'db', 'migrations');
const migrations = fs
  .readdirSync(migrationsDir)
  .filter((f) => f.endsWith('.sql') && !f.endsWith('.down.sql'))
  .sort();
fs.writeFileSync(
  path.join(__dirname, '..', 'src', 'db', 'migrations.generated.json'),
  `${JSON.stringify(migrations, null, 2)}
`,
);

console.log(`[moco-api build] ok (${migrations.length} migrations)`);
