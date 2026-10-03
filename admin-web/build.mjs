// Vercel "Build Command" for the moco-admin project (admin.lovcamx.online).
// Also runnable locally: `node admin-web/build.mjs`.
//
// The admin console stays where it is — moco-backend/public/admin, plain
// static HTML/CSS/JS with no build step — so there is one copy of it, and the
// Node backend can keep serving it at /admin unchanged. This script copies it
// into dist/ for Vercel and checks it.
//
// The console calls the API with relative URLs (`/api/auth/*`, `/api/admin/*`);
// vercel.json proxies exactly those two prefixes to MOCO_BACKEND_ORIGIN, so
// the console and its API are same-origin and the backend needs no CORS.
//
// Requires Vercel's "Include files outside the root directory in the Build
// Step" (on by default), because the source lives outside admin-web/.

import { cpSync, existsSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, '..', 'moco-backend', 'public', 'admin');
const out = join(here, 'dist');
const onVercel = process.env.VERCEL === '1';

const fail = (msg) => {
  console.error(`\n[admin build] ERROR: ${msg}\n`);
  process.exit(1);
};

if (onVercel) {
  const backend = (process.env.MOCO_BACKEND_ORIGIN || '').trim();
  if (!backend) fail('MOCO_BACKEND_ORIGIN is not set. Add it in Vercel → Project → Settings → Environment Variables.');
  let url;
  try {
    url = new URL(backend);
  } catch {
    fail(`MOCO_BACKEND_ORIGIN="${backend}" is not a URL.`);
  }
  if (url.protocol !== 'https:' || url.pathname !== '/') fail('MOCO_BACKEND_ORIGIN must be an https origin with no path, e.g. https://api.lovcamx.online');
  if (!(process.env.MOCO_EDGE_PROXY_SECRET || '').trim()) fail('MOCO_EDGE_PROXY_SECRET is not set.');
}

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

// The console must keep using relative /api URLs — an absolute backend URL
// would bypass the proxy and need CORS.
const js = readFileSync(join(out, 'admin.js'), 'utf8');
if (!/const API = '\/api';/.test(js)) fail("admin.js no longer uses `const API = '/api'` — update vercel.json routing to match.");
if (/https?:\/\/(localhost|127\.0\.0\.1)/.test(js)) fail('admin.js contains a localhost URL.');

console.log(`[admin build] OK — ${readdirSync(out).join(', ')} → admin-web/dist (refs checked: ${refs.join(', ')})`);
