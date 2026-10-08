// Vercel "Build Command" for the moco-admin project (admin.lovcamx.online).
// Also runnable locally: `node admin-web/build.mjs`.
//
// The admin console stays where it is — moco-backend/public/admin, plain
// static HTML/CSS/JS with no build step — so there is one copy of it, and the
// backend's local dev server can keep serving it at /admin. This script copies
// it into dist/ for Vercel and checks it.
//
// The console source calls the API with a relative base (`const API = '/api'`),
// which is right when it is served from the API's own origin in local
// development. In production the API is its own origin,
// https://api.lovcamx.online (the moco-api project), so the copy in dist/ gets
// that absolute base. The API allows this origin via CORS (CORS_ORIGINS on
// moco-api), and vercel.json's CSP allows connecting to it.
//
// Requires Vercel's "Include files outside the root directory in the Build
// Step" (on by default), because the source lives outside admin-web/.

import { cpSync, existsSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, '..', 'moco-backend', 'public', 'admin');
const out = join(here, 'dist');

// Public: the production API (Vercel project moco-api). MOCO_API_ORIGIN
// overrides it for a staging build.
const API_ORIGIN = (process.env.MOCO_API_ORIGIN || 'https://api.lovcamx.online').replace(/\/$/, '');

const fail = (msg) => {
  console.error(`\n[admin build] ERROR: ${msg}\n`);
  process.exit(1);
};

if (!/^https:\/\/[a-z0-9.-]+$/.test(API_ORIGIN)) fail(`MOCO_API_ORIGIN must be an https origin, got "${API_ORIGIN}".`);

if (!existsSync(join(src, 'index.html'))) {
  fail(`${src} not found. In Vercel, enable "Include files outside the root directory in the Build Step" (Settings → Build and Deployment → Root Directory).`);
}

rmSync(out, { recursive: true, force: true });
cpSync(src, out, { recursive: true });

// Every asset index.html references must exist, or the console loads blank.
const html = readFileSync(join(out, 'index.html'), 'utf8');
const refs = [...html.matchAll(/(?:src|href)="([^"#:]+)"/g)].map((m) => m[1]).filter((r) => !r.startsWith('data'));
const missing = refs.filter((r) => !existsSync(join(out, r)));
if (missing.length) fail(`index.html references missing files: ${missing.join(', ')}`);

// Point the console at the production API. Exactly one occurrence must be
// replaced; anything else means admin.js changed shape and this needs a look.
const jsPath = join(out, 'admin.js');
const js = readFileSync(jsPath, 'utf8');
const API_LINE = /const API = '\/api';/g;
const found = js.match(API_LINE)?.length ?? 0;
if (found !== 1) fail(`expected exactly one \`const API = '/api';\` in admin.js, found ${found}.`);
const patched = js.replace(API_LINE, `const API = '${API_ORIGIN}/api';`);
if (/https?:\/\/(localhost|127\.0\.0\.1)/.test(patched)) fail('admin.js contains a localhost URL.');
writeFileSync(jsPath, patched);

// Error reporting (moco-backend/public/admin/monitoring.js): fill in the
// Sentry DSN (SENTRY_DSN on moco-admin — a public client key) and the release.
// Unset: the reporter installs nothing. vercel.json's CSP allows *.sentry.io.
const sentryDsn = (process.env.SENTRY_DSN || '').trim();
if (sentryDsn && !/^https:\/\/[^@\s'"]+@[^/\s'"]+\/\d+$/.test(sentryDsn)) {
  fail('SENTRY_DSN does not look like a Sentry DSN (https://<key>@<host>/<project-id>).');
}
const release = `moco-admin@${(process.env.VERCEL_GIT_COMMIT_SHA || 'local').slice(0, 12)}`;
const monPath = join(out, 'monitoring.js');
const mon = readFileSync(monPath, 'utf8');
const DSN_LINE = "const SENTRY_DSN = '';";
const RELEASE_LINE = "const RELEASE = '';";
for (const line of [DSN_LINE, RELEASE_LINE]) {
  if (mon.split(line).length !== 2) fail(`expected exactly one "${line}" in monitoring.js.`);
}
writeFileSync(
  monPath,
  mon
    .replace(DSN_LINE, `const SENTRY_DSN = '${sentryDsn}';`)
    .replace(RELEASE_LINE, `const RELEASE = '${release}';`),
);

// No server-side secret may end up in the static output. Vercel exposes every
// project variable to the build process, so check the values that exist here.
const SECRET_NAMES = ['DATABASE_URL', 'REDIS_PASSWORD', 'JWT_SECRET', 'CRON_SECRET', 'SUPABASE_SERVICE_ROLE_KEY', 'AGORA_APP_CERTIFICATE', 'PAYMENT_KEY_SECRET', 'SMS_API_KEY', 'FCM_SERVICE_ACCOUNT_JSON'];
const secrets = SECRET_NAMES.map((n) => [n, (process.env[n] || '').trim()]).filter(([, v]) => v.length >= 8);
for (const f of readdirSync(out)) {
  const text = readFileSync(join(out, f), 'latin1');
  for (const [name, value] of secrets) {
    if (text.includes(value)) fail(`the value of ${name} was found in dist/${f}.`);
  }
}

console.log(`[admin build] OK — ${readdirSync(out).join(', ')} → admin-web/dist, API ${API_ORIGIN}/api, monitoring ${sentryDsn ? 'on' : 'off'} (refs checked: ${refs.join(', ')})`);
