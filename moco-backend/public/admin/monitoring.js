'use strict';

/**
 * Error reporting for the admin console (Sentry), dependency-free.
 *
 * admin-web/build.mjs fills in the DSN and release for the production build;
 * with the DSN empty (local development, or monitoring not set up) nothing
 * is installed. A DSN is a public client key, not a secret.
 *
 * Reports uncaught errors and unhandled promise rejections with their stack
 * trace and the page path. Never the query string or hash, form contents,
 * the session token, or API error responses (those are expected failures the
 * console already shows to the operator, and can echo request data).
 */
(() => {
  const SENTRY_DSN = '';
  const RELEASE = '';

  const dsn = /^https:\/\/([^@]+)@([^/]+)\/(\d+)$/.exec(SENTRY_DSN);
  if (!dsn) return;
  const [, publicKey, host, projectId] = dsn;
  const endpoint = `https://${host}/api/${projectId}/envelope/?sentry_version=7&sentry_key=${encodeURIComponent(publicKey)}`;

  const MAX_EVENTS = 10;
  let sent = 0;
  const seen = new Set();

  const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2)).replace(/-/g, '');

  // "at fn (url:line:col)" (Chromium) and "fn@url:line:col" (Firefox, Safari).
  function frames(stack) {
    const out = [];
    for (const line of String(stack || '').split('\n')) {
      const m =
        /^\s*at (?:(.+?) \()?(.+?):(\d+):(\d+)\)?\s*$/.exec(line) || /^\s*(.*?)@(.+?):(\d+):(\d+)\s*$/.exec(line);
      if (!m) continue;
      const file = m[2].split(/[?#]/)[0];
      out.push({ function: m[1] || '?', filename: file, abs_path: file, lineno: Number(m[3]), colno: Number(m[4]), in_app: file.startsWith(location.origin) });
    }
    return out.reverse();
  }

  function report(error, mechanism) {
    // API failures carry an HTTP status; the console handles and shows them.
    if (error && typeof error === 'object' && 'status' in error) return;
    const type = (error && error.name) || 'Error';
    const value = String((error && error.message) || error || 'Unknown error').slice(0, 500);
    const key = `${type}:${value}`;
    if (sent >= MAX_EVENTS || seen.has(key)) return;
    seen.add(key);
    sent += 1;

    const eventId = uuid();
    const event = {
      event_id: eventId,
      timestamp: Date.now() / 1000,
      platform: 'javascript',
      level: 'error',
      environment: 'production',
      release: RELEASE || undefined,
      tags: { app: 'moco-admin', mechanism },
      request: { url: location.origin + location.pathname },
      exception: { values: [{ type, value, stacktrace: { frames: frames(error && error.stack) }, mechanism: { type: mechanism, handled: false } }] },
    };
    const body = `${JSON.stringify({ event_id: eventId, sent_at: new Date().toISOString() })}\n${JSON.stringify({ type: 'event' })}\n${JSON.stringify(event)}`;
    // text/plain keeps this a simple request (no CORS preflight).
    fetch(endpoint, { method: 'POST', body, headers: { 'Content-Type': 'text/plain;charset=UTF-8' }, keepalive: true }).catch(() => {});
  }

  window.addEventListener('error', (e) => report(e.error || e.message, 'onerror'));
  window.addEventListener('unhandledrejection', (e) => report(e.reason, 'onunhandledrejection'));
  // Lets an operator confirm reporting works: open the console with ?monitoring-test.
  if (new URLSearchParams(location.search).has('monitoring-test')) {
    setTimeout(() => report(new Error('Moco admin monitoring test event'), 'test'), 0);
  }
})();
