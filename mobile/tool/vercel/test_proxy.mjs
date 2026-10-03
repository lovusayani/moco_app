// Tests for the Vercel /api proxy function used by moco-web and moco-admin.
//   node --test tool/vercel/test_proxy.mjs        (from mobile/)
//
// Runs the real proxy code against a local HTTP backend, so method, body,
// headers, cookies, redirects and compression go over a real socket.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { gzipSync } from 'node:zlib';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createProxy } from '../../api/_lib/moco_proxy.mjs';

const mobileDir = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const repoDir = join(mobileDir, '..');
const read = (p) => readFileSync(join(repoDir, p), 'utf8');

const SECRET = 'test-edge-secret-0123456789abcdef';
let server;
let origin;
let last; // the last request the mock backend received

before(async () => {
  server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      last = { method: req.method, url: req.url, headers: req.headers, body: Buffer.concat(chunks) };
      if (req.url.startsWith('/api/redirect')) {
        res.writeHead(302, { Location: '/api/elsewhere' });
        return res.end();
      }
      if (req.url.startsWith('/api/cookies')) {
        res.setHeader('Set-Cookie', ['a=1; Path=/; HttpOnly', 'b=2; Path=/; Secure']);
        res.writeHead(201, { 'Content-Type': 'application/json', 'X-Custom': 'kept' });
        return res.end('{"created":true}');
      }
      if (req.url.startsWith('/api/gzip')) {
        res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Encoding': 'gzip' });
        return res.end(gzipSync(Buffer.from('{"zipped":"yes"}')));
      }
      if (req.url.startsWith('/api/cached')) {
        res.writeHead(200, { 'Cache-Control': 'private, max-age=5' });
        return res.end('ok');
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  origin = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

const webProxy = () => createProxy({ origin, allow: /^[^/]/, secret: () => SECRET });
const adminProxy = () => createProxy({ origin, allow: /^(auth|admin)\/./, secret: () => SECRET });

// What Vercel hands the function after the vercel.json rewrite
// /api/:path+ -> /api/moco-proxy?__moco_path=:path+ (original query merged).
const call = (proxy, path, query = '', init = {}) =>
  proxy(
    new Request(`https://lovcamx.online/api/moco-proxy?__moco_path=${path}${query ? `&${query}` : ''}`, {
      ...init,
      headers: { 'x-forwarded-for': '203.0.113.9', ...(init.headers || {}) },
    }),
  );

// --- configuration invariants -------------------------------------------------

test('both projects ship byte-identical proxy cores', () => {
  assert.equal(read('mobile/api/_lib/moco_proxy.mjs'), read('admin-web/api/_lib/moco_proxy.mjs'));
});

test('backend origin is the public api.lovcamx.online everywhere', () => {
  for (const f of ['mobile/api/moco-proxy.mjs', 'admin-web/api/moco-proxy.mjs', 'mobile/tool/vercel/build_web.mjs']) {
    assert.match(read(f), /const BACKEND_ORIGIN = 'https:\/\/api\.lovcamx\.online';/, f);
  }
});

test('vercel.json uses no env substitution and never names the secret', () => {
  for (const f of ['mobile/vercel.json', 'admin-web/vercel.json']) {
    const text = read(f);
    const json = JSON.parse(text);
    assert.ok(!text.includes('${'), `${f} contains \${...}`);
    assert.ok(!/MOCO_EDGE_PROXY_SECRET|MOCO_BACKEND_ORIGIN/.test(text), `${f} references an env var`);
    assert.equal(json.routes, undefined, `${f} must use rewrites/headers, not legacy routes`);
    assert.ok(json.rewrites.every((r) => r.destination.startsWith('/')), `${f} rewrites to an external URL`);
  }
});

test('rewrites capture the path as __moco_path (Vercel passes it on as a query param)', () => {
  const web = JSON.parse(read('mobile/vercel.json')).rewrites[0];
  const admin = JSON.parse(read('admin-web/vercel.json')).rewrites;
  assert.deepEqual(web, { source: '/api/:__moco_path(.+)', destination: '/api/moco-proxy' });
  assert.deepEqual(admin, [{ source: '/api/:__moco_path((?:auth|admin)/.+)', destination: '/api/moco-proxy' }]);
});

test('the secret is only ever read from process.env at runtime', () => {
  const core = read('mobile/api/_lib/moco_proxy.mjs');
  assert.match(core, /process\.env\.MOCO_EDGE_PROXY_SECRET/);
});

// --- request forwarding ---------------------------------------------------------

test('GET: path and query string preserved, __moco_path removed', async () => {
  const res = await call(webProxy(), 'listeners/7/photos', 'lang=hi&tag=a&tag=b&q=%C3%A9t%C3%A9+x');
  assert.equal(res.status, 200);
  const url = new URL(last.url, origin);
  assert.equal(url.pathname, '/api/listeners/7/photos');
  assert.equal(url.searchParams.get('__moco_path'), null);
  assert.deepEqual(url.searchParams.getAll('tag'), ['a', 'b']);
  assert.equal(url.searchParams.get('lang'), 'hi');
  assert.equal(url.searchParams.get('q'), 'été x');
});

test('percent-encoded path segments reach the backend decoded exactly once', async () => {
  // Browser path /api/feed/tag/caf%C3%A9%20x/a%2520b -> Vercel puts the raw
  // capture into the query string.
  await call(webProxy(), 'feed/tag/caf%C3%A9%20x/a%2520b');
  assert.equal(new URL(last.url, origin).pathname, '/api/feed/tag/caf%C3%A9%20x/a%2520b');
});

test('POST/PUT/PATCH/DELETE: method and exact body bytes preserved', async () => {
  const body = '{"phone":"+919876543210","note":"ünïcødé","n":1}';
  for (const method of ['POST', 'PUT', 'PATCH', 'DELETE']) {
    const res = await call(webProxy(), 'chat/threads/3/messages', '', {
      method,
      body,
      headers: { 'content-type': 'application/json' },
    });
    assert.equal(res.status, 200, method);
    assert.equal(last.method, method);
    assert.equal(last.body.toString('utf8'), body);
    assert.equal(last.headers['content-type'], 'application/json');
    assert.equal(Number(last.headers['content-length']), Buffer.byteLength(body));
  }
});

test('Authorization, cookies and custom headers pass through', async () => {
  await call(webProxy(), 'users/me', '', {
    headers: { authorization: 'Bearer abc.def.ghi', cookie: 'sid=1; theme=dark', 'x-app-version': '1.2.3' },
  });
  assert.equal(last.headers.authorization, 'Bearer abc.def.ghi');
  assert.equal(last.headers.cookie, 'sid=1; theme=dark');
  assert.equal(last.headers['x-app-version'], '1.2.3');
});

test('client IP from Vercel is forwarded; secret injected; spoofed headers replaced', async () => {
  await call(webProxy(), 'auth/otp/request', '', {
    method: 'POST',
    body: '{}',
    headers: {
      'x-forwarded-for': '198.51.100.20',
      'x-real-ip': '10.0.0.1',
      'x-moco-edge-secret': 'forged-by-client',
      'x-vercel-id': 'bom1::abc',
      forwarded: 'for=1.1.1.1',
    },
  });
  assert.equal(last.headers['x-forwarded-for'], '198.51.100.20');
  assert.equal(last.headers['x-real-ip'], '198.51.100.20');
  assert.equal(last.headers['x-moco-edge-secret'], SECRET);
  assert.equal(last.headers['x-forwarded-proto'], 'https');
  assert.equal(last.headers['x-forwarded-host'], 'lovcamx.online');
  assert.equal(last.headers['x-vercel-id'], undefined);
  assert.equal(last.headers.forwarded, undefined);
  assert.equal(last.headers.host, new URL(origin).host);
});

test('a malformed client IP is dropped (nginx then uses the peer address)', async () => {
  await call(webProxy(), 'config', '', { headers: { 'x-forwarded-for': 'not-an-ip<script>' } });
  assert.equal(last.headers['x-forwarded-for'], undefined);
  assert.equal(last.headers['x-moco-edge-secret'], SECRET);
});

// --- responses -----------------------------------------------------------------------

test('status, custom headers and every Set-Cookie preserved; no-store added', async () => {
  const res = await call(webProxy(), 'cookies');
  assert.equal(res.status, 201);
  assert.equal(res.headers.get('x-custom'), 'kept');
  assert.deepEqual(res.headers.getSetCookie(), ['a=1; Path=/; HttpOnly', 'b=2; Path=/; Secure']);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await res.json(), { created: true });
  assert.equal(res.headers.get('x-moco-edge-secret'), null);
});

test('upstream Cache-Control is kept as is', async () => {
  const res = await call(webProxy(), 'cached');
  assert.equal(res.headers.get('cache-control'), 'private, max-age=5');
});

test('redirects are passed back, not followed', async () => {
  const res = await call(webProxy(), 'redirect');
  assert.equal(res.status, 302);
  assert.equal(res.headers.get('location'), '/api/elsewhere');
});

test('gzip from upstream is decoded and content-encoding dropped', async () => {
  const res = await call(webProxy(), 'gzip');
  assert.equal(res.headers.get('content-encoding'), null);
  assert.deepEqual(await res.json(), { zipped: 'yes' });
});

test('HEAD returns headers only', async () => {
  const res = await call(webProxy(), 'config', '', { method: 'HEAD' });
  assert.equal(res.status, 200);
  assert.equal(last.method, 'HEAD');
  assert.equal(await res.text(), '');
});

// --- refusals ----------------------------------------------------------------------

test('missing secret: 503, nothing sent upstream', async () => {
  last = undefined;
  const proxy = createProxy({ origin, allow: /^[^/]/, secret: () => '' });
  const res = await call(proxy, 'config');
  assert.equal(res.status, 503);
  assert.equal(last, undefined);
});

test('missing, duplicated or traversing __moco_path: 404, nothing sent upstream', async () => {
  for (const url of [
    'https://lovcamx.online/api/moco-proxy',
    'https://lovcamx.online/api/moco-proxy?__moco_path=users/me&__moco_path=admin/stats',
    'https://lovcamx.online/api/moco-proxy?__moco_path=../health',
    'https://lovcamx.online/api/moco-proxy?__moco_path=users/%2e%2e/%2e%2e/health',
    'https://lovcamx.online/api/moco-proxy?__moco_path=users%2F..%2F..%2Fhealth',
    'https://lovcamx.online/api/moco-proxy?__moco_path=',
  ]) {
    last = undefined;
    const res = await webProxy()(new Request(url));
    assert.equal(res.status, 404, url);
    assert.equal(last, undefined, url);
  }
});

test('admin proxy: only /api/auth/* and /api/admin/*', async () => {
  for (const [path, status] of [
    ['auth/otp/request', 200],
    ['admin/stats', 200],
    ['admin/users/5/status', 200],
    ['users/me', 404],
    ['config', 404],
    ['wallet/balance', 404],
    ['admin', 404],
    ['administrator/x', 404],
  ]) {
    last = undefined;
    const res = await call(adminProxy(), path);
    assert.equal(res.status, status, path);
    if (status === 200) assert.equal(new URL(last.url, origin).pathname, `/api/${path}`);
    else assert.equal(last, undefined, path);
  }
});

test('backend unreachable: 502; timeout: 504 (JSON error shape matches the API)', async () => {
  const down = createProxy({ origin: 'http://127.0.0.1:1', allow: /./, secret: () => SECRET });
  const res = await call(down, 'config');
  assert.equal(res.status, 502);
  assert.equal((await res.json()).error.code, 'upstream_unreachable');

  const slow = createProxy({
    origin,
    allow: /./,
    secret: () => SECRET,
    fetchImpl: async () => {
      throw Object.assign(new Error('timed out'), { name: 'TimeoutError' });
    },
  });
  const res2 = await call(slow, 'config');
  assert.equal(res2.status, 504);
  assert.equal((await res2.json()).error.code, 'upstream_timeout');
});
