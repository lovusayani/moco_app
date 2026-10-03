'use strict';

/**
 * CORS and WebSocket origin policy for the separate-origin production layout
 * (lovcamx.online / admin.lovcamx.online → api.lovcamx.online).
 *
 * Needs no database: /health and preflights never touch Postgres, and a
 * socket refused by origin is refused before anything reaches Redis.
 */

process.env.CORS_ORIGINS = 'https://lovcamx.online,https://admin.lovcamx.online';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const WebSocket = require('ws');
const { createApp } = require('../src/app');
const socketServer = require('../src/realtime/socket.server');
const { isAllowedOrigin } = require('../src/middleware/cors');

let server;
let base;

test.before(async () => {
  server = http.createServer(createApp());
  socketServer.init(server);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  socketServer.getIo()?.close();
  await new Promise((resolve) => server.close(resolve));
  // The app's shared clients were opened at require time.
  await require('../src/config/db').close().catch(() => {});
  require('../src/config/redis').redis.disconnect();
});

test('allowed origins are the configured list; nothing else, never "*"', () => {
  assert.equal(isAllowedOrigin('https://lovcamx.online'), true);
  assert.equal(isAllowedOrigin('https://admin.lovcamx.online'), true);
  assert.equal(isAllowedOrigin('https://evil.example'), false);
  assert.equal(isAllowedOrigin('https://lovcamx.online.evil.example'), false);
  assert.equal(isAllowedOrigin(undefined), false);
});

test('an allowed origin gets CORS headers for that origin only', async () => {
  const res = await fetch(`${base}/health`, { headers: { Origin: 'https://lovcamx.online' } });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('access-control-allow-origin'), 'https://lovcamx.online');
  assert.equal(res.headers.get('access-control-allow-credentials'), null);
  assert.match(res.headers.get('vary'), /Origin/);
});

test('an unknown origin gets no CORS headers', async () => {
  const res = await fetch(`${base}/health`, { headers: { Origin: 'https://evil.example' } });
  assert.equal(res.headers.get('access-control-allow-origin'), null);
});

test('requests without an Origin (Android app, webhooks) are unaffected', async () => {
  const res = await fetch(`${base}/health`);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('access-control-allow-origin'), null);
});

test('preflight from an allowed origin allows the Authorization header', async () => {
  const res = await fetch(`${base}/api/users/me`, {
    method: 'OPTIONS',
    headers: {
      Origin: 'https://admin.lovcamx.online',
      'Access-Control-Request-Method': 'PATCH',
      'Access-Control-Request-Headers': 'authorization, content-type',
    },
  });
  assert.equal(res.status, 204);
  assert.equal(res.headers.get('access-control-allow-origin'), 'https://admin.lovcamx.online');
  assert.match(res.headers.get('access-control-allow-methods'), /PATCH/);
  assert.match(res.headers.get('access-control-allow-headers'), /authorization/i);
});

test('preflight from an unknown origin is refused', async () => {
  const res = await fetch(`${base}/api/users/me`, {
    method: 'OPTIONS',
    headers: { Origin: 'https://evil.example', 'Access-Control-Request-Method': 'GET' },
  });
  assert.equal(res.status, 403);
  assert.equal(res.headers.get('access-control-allow-origin'), null);
});

test('responses stay readable cross-origin (CORP is not same-origin)', async () => {
  const res = await fetch(`${base}/health`, { headers: { Origin: 'https://lovcamx.online' } });
  assert.equal(res.headers.get('cross-origin-resource-policy'), 'cross-origin');
});

function openSocket(headers) {
  const url = `${base.replace('http', 'ws')}/socket.io/?EIO=4&transport=websocket`;
  return new Promise((resolve) => {
    const ws = new WebSocket(url, { headers });
    ws.on('open', () => {
      ws.close();
      resolve('open');
    });
    ws.on('unexpected-response', (_req, res) => resolve(res.statusCode));
    ws.on('error', () => resolve('error'));
  });
}

test('websocket from an allowed browser origin is accepted', async () => {
  assert.equal(await openSocket({ Origin: 'https://lovcamx.online' }), 'open');
});

test('websocket without an Origin (Android app) is accepted', async () => {
  assert.equal(await openSocket({}), 'open');
});

test('websocket from an unknown browser origin is refused', async () => {
  const result = await openSocket({ Origin: 'https://evil.example' });
  assert.notEqual(result, 'open');
});
