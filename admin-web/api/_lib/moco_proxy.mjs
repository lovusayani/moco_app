// Server-side /api proxy shared by the two Vercel projects (moco-web and
// moco-admin). It runs as a Vercel Function, never in the browser.
//
// KEEP IN SYNC: mobile/api/_lib/moco_proxy.mjs and
// admin-web/api/_lib/moco_proxy.mjs must be byte-identical (each Vercel
// project bundles only its own root directory).
// tool/vercel/test_proxy.mjs checks this.
//
// What it does, per request:
//   * forwards method, body bytes, query string, cookies, Authorization and
//     every other end-to-end header to <origin>/api/<path>, unchanged;
//   * replaces any client-sent X-Forwarded-For / X-Real-IP with the client IP
//     Vercel reports (Vercel overwrites X-Forwarded-For at its edge, so a
//     client cannot spoof it);
//   * adds X-Moco-Edge-Secret from the MOCO_EDGE_PROXY_SECRET runtime env var,
//     so nginx trusts that IP (moco-backend/nginx/moco.conf). The secret is
//     read from process.env at request time. It is not in any committed file
//     or in the static output, and is never sent back to the browser;
//   * streams the backend's response back as is: status, headers (including
//     every Set-Cookie) and redirects (not followed).
//
// vercel.json rewrites the page origin's /api/<path> to this function. The
// rewrite source names its capture __moco_path, and Vercel passes named
// captures on as query parameters, so the function sees
// /api/moco-proxy?__moco_path=<path>&<original query>. The original query
// string goes to the backend minus __moco_path.

const PATH_PARAM = '__moco_path';
const UPSTREAM_TIMEOUT_MS = 30_000; // matches nginx proxy_read_timeout for /api

// Hop-by-hop headers (RFC 9110 §7.6.1) and headers the proxy sets itself.
const DROP_REQUEST = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'proxy-connection',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'host',
  'content-length',
  // fetch negotiates and decodes compression itself.
  'accept-encoding',
  // Client IP and proxy identity are set below and must not be client-supplied.
  'forwarded',
  'x-forwarded-for',
  'x-forwarded-host',
  'x-forwarded-proto',
  'x-forwarded-port',
  'x-real-ip',
  'x-moco-edge-secret',
]);

const DROP_RESPONSE = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-connection',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  // fetch already decoded the body, so the original encoding and length are
  // no longer true. The platform recomputes them.
  'content-encoding',
  'content-length',
]);

// eslint-disable-next-line no-control-regex
const UNSAFE_SEGMENT = /[/\\\u0000-\u001f\u007f]/;

const errorResponse = (status, code, message) =>
  Response.json({ error: { code, message } }, { status, headers: { 'cache-control': 'no-store' } });

/** First address of an X-Forwarded-For list, if it looks like an IP. */
function clientIp(headers) {
  const first = (headers.get('x-forwarded-for') || '').split(',')[0].trim();
  const ip = first || (headers.get('x-real-ip') || '').trim();
  return /^[0-9A-Fa-f:.]{2,45}$/.test(ip) ? ip : '';
}

/**
 * @param {object} options
 * @param {string} options.origin   backend origin, e.g. https://api.lovcamx.online
 * @param {RegExp} options.allow    which `/api/<path>` paths may be proxied
 * @param {() => string | undefined} [options.secret]  edge secret (default: process.env)
 * @param {typeof fetch} [options.fetchImpl]
 */
export function createProxy({ origin, allow, secret = () => process.env.MOCO_EDGE_PROXY_SECRET, fetchImpl = fetch }) {
  const base = new URL(origin);

  return async function proxy(request) {
    const url = new URL(request.url);
    const params = url.searchParams;

    // Exactly one __moco_path: the one the vercel.json rewrite added. A second,
    // client-supplied copy is ambiguous, so it is rejected, not guessed.
    const paths = params.getAll(PATH_PARAM);
    if (paths.length !== 1) return errorResponse(404, 'not_found', 'Unknown endpoint');
    params.delete(PATH_PARAM);

    // URLSearchParams has already decoded the value once. That is the only
    // decode, so the backend gets exactly the path the browser sent. Each
    // segment is re-encoded, and none may climb out of /api/ ("..") or
    // carry a separator or control character.
    const segments = paths[0].split('/').filter((s) => s !== '');
    if (!segments.length || segments.some((s) => s === '.' || s === '..' || UNSAFE_SEGMENT.test(s))) {
      return errorResponse(404, 'not_found', 'Unknown endpoint');
    }
    const path = segments.map(encodeURIComponent).join('/');
    if (!allow.test(path)) return errorResponse(404, 'not_found', 'Unknown endpoint');

    const edgeSecret = (secret() || '').trim();
    if (!edgeSecret) {
      console.error('[moco-proxy] MOCO_EDGE_PROXY_SECRET is not set; refusing to proxy.');
      return errorResponse(503, 'proxy_misconfigured', 'Service temporarily unavailable');
    }

    const target = new URL(`/api/${path}`, base);
    target.search = params.toString();

    const headers = new Headers();
    for (const [name, value] of request.headers) {
      const key = name.toLowerCase();
      if (DROP_REQUEST.has(key) || key.startsWith('x-vercel-')) continue;
      headers.append(name, value);
    }
    const ip = clientIp(request.headers);
    if (ip) {
      headers.set('x-forwarded-for', ip);
      headers.set('x-real-ip', ip);
    }
    headers.set('x-forwarded-proto', 'https');
    headers.set('x-forwarded-host', url.host);
    headers.set('x-moco-edge-secret', edgeSecret);

    const method = request.method.toUpperCase();
    const hasBody = method !== 'GET' && method !== 'HEAD';

    let upstream;
    try {
      upstream = await fetchImpl(target, {
        method,
        headers,
        body: hasBody ? await request.arrayBuffer() : undefined,
        redirect: 'manual',
        signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
      });
    } catch (err) {
      const timedOut = err?.name === 'TimeoutError';
      console.error(`[moco-proxy] ${method} /api/${path} failed: ${err?.name}: ${err?.message}`);
      return timedOut
        ? errorResponse(504, 'upstream_timeout', 'The server took too long to respond')
        : errorResponse(502, 'upstream_unreachable', 'The server could not be reached');
    }

    const out = new Headers();
    for (const [name, value] of upstream.headers) {
      if (name.toLowerCase() === 'set-cookie') continue; // appended individually below
      if (!DROP_RESPONSE.has(name.toLowerCase())) out.append(name, value);
    }
    for (const cookie of upstream.headers.getSetCookie?.() ?? []) out.append('set-cookie', cookie);
    // API responses are per-user. Never let a CDN keep one.
    if (!out.has('cache-control')) out.set('cache-control', 'no-store');

    return new Response(method === 'HEAD' ? null : upstream.body, {
      status: upstream.status,
      statusText: upstream.statusText,
      headers: out,
    });
  };
}
