// Vercel "Build Command" for the moco-web project (lovcamx.online).
// Also runnable locally: `node tool/vercel/build_web.mjs` (uses `flutter` on
// PATH).
//
// The web app talks to the API on its own origin, https://api.lovcamx.online
// (the moco-api Vercel project): REST at /api and Socket.IO at the root. Both
// are public addresses baked into the bundle with --dart-define. The API
// allows this site's origin via CORS (CORS_ORIGINS on moco-api).
//
// Build-time configuration (optional Vercel project environment variables):
//
//   MOCO_API_ORIGIN   API origin. Default: API_ORIGIN below.
//   MOCO_FLAVOR       default "production". "staging" or "development" are
//                     refused for the production deployment.
//   SENTRY_DSN        Sentry DSN for crash/error reporting (a public client
//                     key, not a secret). Unset: reporting is off.
//
// This project has no secrets. The build still fails if the value of any
// known server-side secret present in the build environment shows up in the
// output.

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const appDir = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const outDir = join(appDir, 'build', 'web');
const onVercel = process.env.VERCEL === '1';

// Public: the production API (Vercel project moco-api).
const API_ORIGIN = 'https://api.lovcamx.online';

const fail = (msg) => {
  console.error(`\n[build_web] ERROR: ${msg}\n`);
  process.exit(1);
};

// --- configuration -----------------------------------------------------------

function origin(name) {
  const raw = (process.env[name] || '').trim();
  if (!raw) return '';
  let url;
  try {
    url = new URL(raw);
  } catch {
    fail(`${name}="${raw}" is not a URL.`);
  }
  if (url.pathname !== '/' || url.search || url.hash) fail(`${name} must be an origin only (no path), e.g. https://api.lovcamx.online`);
  if (onVercel && url.protocol !== 'https:') fail(`${name} must use https:// in a Vercel build.`);
  return url.origin;
}

const apiOrigin = origin('MOCO_API_ORIGIN') || API_ORIGIN;
const flavor = process.env.MOCO_FLAVOR || 'production';
if (!['production', 'staging', 'development'].includes(flavor)) fail(`MOCO_FLAVOR="${flavor}" is not production|staging|development.`);
if (onVercel && process.env.VERCEL_ENV === 'production' && flavor !== 'production') {
  fail(`MOCO_FLAVOR must be "production" for the production deployment (got "${flavor}").`);
}

// --- build -------------------------------------------------------------------

const flutterHome = process.env.FLUTTER_HOME || join(homedir(), 'flutter-sdk');
const flutter = onVercel ? join(flutterHome, 'flutter', 'bin', 'flutter') : 'flutter';

// The build id doubles as the Sentry release, so an error report names the
// exact deployment (see "per-build asset URLs" below).
const buildId = (process.env.VERCEL_GIT_COMMIT_SHA || '').slice(0, 12) || Date.now().toString(36);
const sentryDsn = (process.env.SENTRY_DSN || '').trim();
if (sentryDsn && !/^https:\/\/[^@\s]+@[^/\s]+\/\d+$/.test(sentryDsn)) fail('SENTRY_DSN does not look like a Sentry DSN (https://<key>@<host>/<project-id>).');

const defines = [`FLAVOR=${flavor}`, `API_BASE_URL=${apiOrigin}/api`, `SOCKET_URL=${apiOrigin}`];
if (sentryDsn) defines.push(`SENTRY_DSN=${sentryDsn}`, `MOCO_RELEASE=moco-web@${buildId}`);

const args = ['build', 'web', '--release', '--no-wasm-dry-run', ...defines.map((d) => `--dart-define=${d}`)];
console.log(`[build_web] flutter ${args.join(' ')}`);
execFileSync(flutter, args, { cwd: appDir, stdio: 'inherit', shell: process.platform === 'win32' });

// --- verify output -----------------------------------------------------------

const REQUIRED = [
  'index.html',
  'flutter_bootstrap.js',
  'main.dart.js',
  'sw.js',
  'manifest.json',
  'favicon.png',
  'icons/Icon-192.png',
  'icons/Icon-512.png',
  'icons/Icon-maskable-192.png',
  'icons/Icon-maskable-512.png',
  'icons/apple-touch-icon.png',
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.wasm',
  'assets/AssetManifest.bin.json',
  'assets/FontManifest.json',
];
const missing = REQUIRED.filter((f) => !existsSync(join(outDir, f)));
if (missing.length) fail(`build/web is missing: ${missing.join(', ')}`);

const index = readFileSync(join(outDir, 'index.html'), 'utf8');
if (!index.includes('<base href="/">')) fail('index.html must have <base href="/"> (path routing and the service worker assume the site root).');

// --- per-build asset URLs --------------------------------------------------
// Flutter's output is not content-hashed: main.dart.js and
// flutter_bootstrap.js keep their names across builds. Behind Cloudflare's
// proxy, the zone's Browser Cache TTL rewrites our `Cache-Control: no-cache`
// on .js files to `max-age=14400`, so a returning browser kept running the
// PREVIOUS build for up to 4 hours after a deploy (and the service worker's
// network-first fetch went through that same browser cache). Stamping both
// URLs with the build id makes every deploy fetch brand-new URLs that no
// browser, service worker or CDN cache has seen. index.html itself is not
// cached by Cloudflare (it stays `no-cache`), so it always points at the
// current build. Because a stamped URL never changes content, vercel.json
// serves the stamped requests as `immutable`; the unstamped names stay
// `no-cache`.
const stamp = (file, from, to, what) => {
  const path = join(outDir, file);
  const text = readFileSync(path, 'utf8');
  const count = text.split(from).length - 1;
  if (count !== 1) fail(`expected exactly one ${what} in ${file}, found ${count} — the Flutter output format changed; update build_web.mjs.`);
  writeFileSync(path, text.replace(from, to));
};
stamp('index.html', 'src="flutter_bootstrap.js"', `src="flutter_bootstrap.js?v=${buildId}"`, 'flutter_bootstrap.js script tag');
stamp('flutter_bootstrap.js', '"mainJsPath":"main.dart.js"', `"mainJsPath":"main.dart.js?v=${buildId}"`, 'mainJsPath');

// No server-side secret may end up in the static output. Vercel exposes every
// project variable to the build process, so check the values that exist here.
const SECRET_NAMES = [
  'DATABASE_URL',
  'PGPASSWORD',
  'REDIS_PASSWORD',
  'REDIS_URL',
  'JWT_SECRET',
  'CRON_SECRET',
  'GOOGLE_PLAY_SERVICE_ACCOUNT_JSON',
  'SUPABASE_SERVICE_ROLE_KEY',
  'AGORA_APP_CERTIFICATE',
  'AGORA_CUSTOMER_SECRET',
  'AGORA_WEBHOOK_SECRET',
  'PAYMENT_KEY_SECRET',
  'PAYMENT_WEBHOOK_SECRET',
  'SMS_API_KEY',
  'FCM_SERVICE_ACCOUNT_JSON',
];
const secrets = SECRET_NAMES.map((n) => [n, (process.env[n] || '').trim()]).filter(([, v]) => v.length >= 8);
function* walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* walk(p);
    else yield p;
  }
}
let files = 0;
for (const file of walk(outDir)) {
  files++;
  if (!secrets.length) continue;
  const text = readFileSync(file, 'latin1');
  for (const [name, value] of secrets) {
    if (text.includes(value)) fail(`the value of ${name} was found in ${relative(appDir, file)} — refusing to deploy it.`);
  }
}

console.log(
  `[build_web] OK — ${files} files in build/web, flavor=${flavor}, ` +
    `api=${apiOrigin}/api, socket=${apiOrigin}, build=${buildId}, monitoring=${sentryDsn ? 'on' : 'off'}, ` +
    `secret scan: ${secrets.length} value(s) checked.`,
);
