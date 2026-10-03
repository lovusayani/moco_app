// Local server for the Moco PWA build — mirrors the production nginx layout
// (see web_deploy/nginx-moco-web.conf) so the web app can be tested exactly as
// it will be served:
//
//   * build/web as static files, index.html for any unknown path (SPA deep
//     links and refresh). Flutter's output is not content-hashed (main.dart.js
//     keeps its name across builds), so everything is `no-cache` +
//     Last-Modified revalidation (a 304 costs one round trip, not a download);
//   * /api, /socket.io and /health proxied to the backend (WebSocket upgrades
//     included), so the app talks to the API same-origin with no CORS.
//
// No dependencies — plain Node 18+.
//
//   node tool/serve_web.mjs [--port 8080] [--backend http://localhost:3000] [--root build/web]
//
// localhost is a secure context, so the service worker, install prompt and
// WebCrypto-backed session storage all work here without HTTPS.

import { createServer, request as httpRequest } from 'node:http';
import { connect } from 'node:net';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};

const port = Number(arg('--port', '8080'));
const backend = new URL(arg('--backend', 'http://localhost:3000'));
const root = resolve(arg('--root', fileURLToPath(new URL('../build/web', import.meta.url))));

const PROXIED = ['/api/', '/socket.io/', '/health'];
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.svg': 'image/svg+xml',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.woff2': 'font/woff2',
  '.bin': 'application/octet-stream',
  '.frag': 'application/octet-stream',
  '.map': 'application/json; charset=utf-8',
};

const isProxied = (path) => PROXIED.some((p) => path === p.replace(/\/$/, '') || path.startsWith(p));

function proxy(req, res) {
  const upstream = httpRequest(
    {
      hostname: backend.hostname,
      port: backend.port,
      path: req.url,
      method: req.method,
      headers: { ...req.headers, host: backend.host, 'x-forwarded-proto': 'http' },
    },
    (up) => {
      res.writeHead(up.statusCode ?? 502, up.headers);
      up.pipe(res);
    },
  );
  upstream.on('error', () => {
    res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end('Backend unreachable at ' + backend.origin);
  });
  req.pipe(upstream);
}

async function serveStatic(req, res) {
  const pathname = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  let file = normalize(join(root, pathname));
  if (file !== root && !file.startsWith(root + sep)) {
    res.writeHead(403).end();
    return;
  }

  let served = pathname;
  try {
    const info = await stat(file);
    if (info.isDirectory()) {
      file = join(file, 'index.html');
      served = '/index.html';
    }
  } catch {
    // Unknown path: an in-app route (/discovery, /chat/12). Hand back the
    // app shell and let the Flutter router resolve it. A missing *asset*
    // (has an extension) is a real 404, not the shell.
    if (extname(pathname)) {
      res.writeHead(404, { 'Content-Type': 'text/plain' }).end('Not found');
      return;
    }
    file = join(root, 'index.html');
    served = '/index.html';
  }

  try {
    const info = await stat(file);
    const lastModified = info.mtime.toUTCString();
    const headers = {
      'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream',
      'Cache-Control': 'no-cache',
      'Last-Modified': lastModified,
      'X-Content-Type-Options': 'nosniff',
    };
    const since = req.headers['if-modified-since'];
    if (since && new Date(since) >= new Date(lastModified)) {
      res.writeHead(304, headers).end();
      return;
    }
    const body = await readFile(file);
    res.writeHead(200, headers);
    res.end(req.method === 'HEAD' ? undefined : body);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain' }).end('Not found — run `flutter build web` first');
  }
}

const server = createServer((req, res) => {
  const path = new URL(req.url, 'http://x').pathname;
  if (isProxied(path)) return proxy(req, res);
  return serveStatic(req, res);
});

// WebSocket upgrade for Socket.IO: pipe the raw TCP stream to the backend.
server.on('upgrade', (req, socket, head) => {
  if (!isProxied(new URL(req.url, 'http://x').pathname)) return socket.destroy();
  const upstream = connect(Number(backend.port || 80), backend.hostname, () => {
    const headers = Object.entries({ ...req.headers, host: backend.host })
      .map(([k, v]) => `${k}: ${v}`)
      .join('\r\n');
    upstream.write(`${req.method} ${req.url} HTTP/1.1\r\n${headers}\r\n\r\n`);
    if (head?.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
});

server.listen(port, () => {
  console.log(`Moco web: http://localhost:${port}  (static ${root}, API -> ${backend.origin})`);
});
