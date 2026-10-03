// Vercel "Build Command" for the moco-admin project (admin.lovcamx.online).
// Also runnable locally: `node admin-web/build.mjs`.
//
// The admin console stays where it is — moco-backend/public/admin, plain
// static HTML/CSS/JS with no build step — so there is one copy of it, and the
// Node backend can keep serving it at /admin unchanged. This script copies it
// into dist/ for Vercel and checks it.
//
// The console calls the API with relative URLs (`/api/auth/*`, `/api/admin/*`);
// vercel.json rewrites exactly those two prefixes to the api/moco-proxy.mjs
// function, which forwards them to https://api.lovcamx.online. The console and
// its API are therefore same-origin, and the backend needs no CORS.
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

// A runtime secret of the proxy function. This only checks that it is set, so
// a missing one fails the deploy instead of every /api request.
if (onVercel && !(process.env.MOCO_EDGE_PROXY_SECRET || '').trim()) {
  fail('MOCO_EDGE_PROXY_SECRET is not set. Add it in Vercel → Project → Settings → Environment Variables (Production, Sensitive).');
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

const secret = (process.env.MOCO_EDGE_PROXY_SECRET || '').trim();
if (secret.length >= 8) {
  for (const f of readdirSync(out)) {
    if (readFileSync(join(out, f), 'latin1').includes(secret)) fail(`the MOCO_EDGE_PROXY_SECRET value was found in dist/${f}.`);
  }
}

console.log(`[admin build] OK — ${readdirSync(out).join(', ')} → admin-web/dist (refs checked: ${refs.join(', ')})`);
