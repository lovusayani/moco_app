// Vercel "Build Command" for the moco-web project (lovcamx.online).
// Also runnable locally: `node tool/vercel/build_web.mjs` (uses `flutter` on
// PATH; set MOCO_BACKEND_ORIGIN to mimic production).
//
// Build-time configuration (Vercel project environment variables):
//
//   MOCO_BACKEND_ORIGIN  required on Vercel. Origin of the Node backend, e.g.
//                        https://api.lovcamx.online. vercel.json proxies
//                        /api/* there, and the web app opens its Socket.IO
//                        connection there directly (Vercel cannot proxy
//                        WebSockets). Public: it is visible in the bundle.
//   MOCO_SOCKET_URL      optional. Overrides the Socket.IO origin.
//   MOCO_FLAVOR          optional, default "production". "staging" or
//                        "development" for preview builds only.
//   MOCO_EDGE_PROXY_SECRET  required on Vercel. Used ONLY by vercel.json (sent
//                        to nginx on proxied /api requests so the backend can
//                        trust the client IP Vercel reports). It is never
//                        passed to Flutter; this script fails the build if it
//                        ever shows up in the output.
//
// The API base URL is deliberately not set: on web the app defaults to its own
// origin (`https://lovcamx.online/api`), which vercel.json proxies to the
// backend — same-origin, so the backend needs no CORS policy.

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const appDir = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const outDir = join(appDir, 'build', 'web');
const onVercel = process.env.VERCEL === '1';

const fail = (msg) => {
  console.error(`\n[build_web] ERROR: ${msg}\n`);
  process.exit(1);
};

// --- configuration -----------------------------------------------------------

function origin(name, { required }) {
  const raw = (process.env[name] || '').trim();
  if (!raw) {
    if (required) fail(`${name} is not set. Add it in Vercel → Project → Settings → Environment Variables.`);
    return '';
  }
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

const backendOrigin = origin('MOCO_BACKEND_ORIGIN', { required: onVercel });
const socketUrl = origin('MOCO_SOCKET_URL', { required: false }) || backendOrigin;
const flavor = process.env.MOCO_FLAVOR || 'production';
if (!['production', 'staging', 'development'].includes(flavor)) fail(`MOCO_FLAVOR="${flavor}" is not production|staging|development.`);
if (onVercel && process.env.VERCEL_ENV === 'production' && flavor !== 'production') {
  fail(`MOCO_FLAVOR must be "production" for the production deployment (got "${flavor}").`);
}
if (onVercel && !(process.env.MOCO_EDGE_PROXY_SECRET || '').trim()) {
  fail('MOCO_EDGE_PROXY_SECRET is not set. vercel.json sends it to nginx with every proxied /api request.');
}

// --- build -------------------------------------------------------------------

const flutterHome = process.env.FLUTTER_HOME || join(homedir(), 'flutter-sdk');
const flutter = onVercel ? join(flutterHome, 'flutter', 'bin', 'flutter') : 'flutter';

const defines = [`FLAVOR=${flavor}`];
if (socketUrl) defines.push(`SOCKET_URL=${socketUrl}`);

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

// No server-side secret may end up in the static output. Vercel exposes every
// project variable to the build process, so check the values that exist here.
const SECRET_NAMES = [
  'MOCO_EDGE_PROXY_SECRET',
  'DATABASE_URL',
  'PGPASSWORD',
  'REDIS_PASSWORD',
  'REDIS_URL',
  'JWT_SECRET',
  'SUPABASE_SERVICE_ROLE_KEY',
  'AGORA_APP_CERTIFICATE',
  'AGORA_CUSTOMER_SECRET',
  'AGORA_WEBHOOK_SECRET',
  'PAYMENT_KEY_SECRET',
  'PAYMENT_WEBHOOK_SECRET',
  'SMS_API_KEY',
  'FCM_SERVER_KEY',
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
    `socket=${socketUrl || '(page origin)'}, api=(page origin)/api, ` +
    `secret scan: ${secrets.length} value(s) checked.`,
);
