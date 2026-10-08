'use strict';

/**
 * Error monitoring (Sentry) for moco-api.
 *
 * On only when SENTRY_DSN is set; otherwise every function here is a no-op
 * and the SDK is never loaded.
 *
 * What reaches Sentry: every error-level log line (src/utils/logger.js hooks
 * in here), so unhandled route errors, Redis and Postgres connection errors,
 * failed pushes, failed OTP email deliveries and realtime errors are all
 * covered without touching each call site; failed queue jobs
 * (src/jobs/handlers.js); and uncaught exceptions / unhandled rejections.
 *
 * What never does: request bodies, headers, cookies, query strings, IP
 * addresses, or arbitrary log fields. Only the error (name, message, stack)
 * and an allow-list of operational fields below are sent, so a token, a code,
 * an email address or a phone number logged next to an error stays in the
 * Vercel logs and is not copied to a third party.
 */

const env = require('../config/env');

const CONTEXT_FIELDS = new Set([
  'path',
  'method',
  'status',
  'statusCode',
  'userId',
  'callId',
  'listenerId',
  'payoutId',
  'topic',
  'channel',
  'identity',
  'type',
  'fcmStatus',
  'deliveryCount',
]);

// One report per distinct message per instance per window: a Redis outage
// logs on every reconnect attempt, and one event says as much as a thousand.
const THROTTLE_MS = 60_000;
const lastSent = new Map();

// The SDK in use: @sentry/core once init() has run (or a stub in tests).
let Sentry = null;

/**
 * Sends envelopes with the platform fetch. @sentry/core is used directly
 * rather than @sentry/node: this service only reports errors, and the full
 * Node SDK (OpenTelemetry and its auto-instrumentation) would add well over
 * half a second to every cold start of every function.
 */
function fetchTransport(core) {
  return (options) =>
    core.createTransport(options, async (request) => {
      const response = await fetch(options.url, {
        method: 'POST',
        body: request.body,
        headers: options.headers,
        signal: AbortSignal.timeout(5000),
      });
      return {
        statusCode: response.status,
        headers: {
          'x-sentry-rate-limits': response.headers.get('X-Sentry-Rate-Limits'),
          'retry-after': response.headers.get('Retry-After'),
        },
      };
    });
}

function init() {
  const dsn = (process.env.SENTRY_DSN || '').trim();
  if (!dsn || Sentry || env.isTest) return;
  // eslint-disable-next-line global-require
  const core = require('@sentry/core');
  const commit = (process.env.VERCEL_GIT_COMMIT_SHA || '').slice(0, 12);
  const client = new core.ServerRuntimeClient({
    dsn,
    environment: process.env.VERCEL_ENV || env.nodeEnv,
    release: commit ? `moco-api@${commit}` : undefined,
    platform: 'node',
    runtime: { name: 'node', version: process.version },
    sendDefaultPii: false,
    maxBreadcrumbs: 0,
    transport: fetchTransport(core),
    stackParser: core.createStackParser(core.nodeStackLineParser()),
    integrations: [core.dedupeIntegration(), core.linkedErrorsIntegration(), core.functionToStringIntegration()],
    beforeSend: scrubEvent,
  });
  core.setCurrentClient(client);
  client.init();
  Sentry = core;

  // Crashes: observe without changing Node's own crash behaviour (the
  // "Monitor" event never prevents the process from exiting).
  process.on('uncaughtExceptionMonitor', (err) => {
    core.withScope((scope) => {
      scope.setTag('crash', 'uncaught');
      core.captureException(err);
    });
  });
}

/** Removes anything request-shaped an integration may have attached. */
function scrubEvent(event) {
  if (event.request) {
    const url = event.request.url ? String(event.request.url).split(/[?#]/)[0] : undefined;
    event.request = { method: event.request.method, url };
  }
  delete event.user;
  if (event.contexts) delete event.contexts.request;
  return event;
}

function pickContext(fields) {
  const out = {};
  if (!fields || typeof fields !== 'object') return out;
  for (const [key, value] of Object.entries(fields)) {
    if (!CONTEXT_FIELDS.has(key)) continue;
    if (['string', 'number', 'boolean'].includes(typeof value)) out[key] = value;
  }
  return out;
}

function throttled(key) {
  const now = Date.now();
  const last = lastSent.get(key) || 0;
  if (now - last < THROTTLE_MS) return true;
  lastSent.set(key, now);
  if (lastSent.size > 500) lastSent.clear();
  return false;
}

/**
 * Reports an error-level log line. `fields` is the pino merge object (may
 * hold `err`), `msg` the log message.
 */
function captureLog(fields, msg) {
  if (!Sentry) return;
  const err = fields && fields.err;
  const message = msg || (err && err.message) || 'error';
  if (throttled(message)) return;
  const context = pickContext(fields);
  Sentry.withScope((scope) => {
    scope.setTag('log_message', String(message).slice(0, 200));
    for (const [k, v] of Object.entries(context)) scope.setTag(k, String(v).slice(0, 200));
    if (err instanceof Error) {
      Sentry.captureException(err);
    } else if (err && typeof err === 'object' && (err.message || err.name)) {
      // Errors logged as plain objects ({ name, message }) to keep them small.
      const e = new Error(`${err.name ? `${err.name}: ` : ''}${err.message || ''}`.trim() || message);
      Sentry.captureException(e);
    } else {
      Sentry.captureMessage(String(message), 'error');
    }
  });
  scheduleFlush();
}

/** Reports an exception with an allow-listed context. */
function captureException(err, fields = {}) {
  if (!Sentry) return;
  Sentry.withScope((scope) => {
    for (const [k, v] of Object.entries(pickContext(fields))) scope.setTag(k, String(v).slice(0, 200));
    Sentry.captureException(err);
  });
  scheduleFlush();
}

/**
 * Vercel may freeze a function as soon as its response is sent, so a queued
 * report is flushed under waitUntil (keeps the instance alive just for that).
 */
function scheduleFlush() {
  try {
    // eslint-disable-next-line global-require
    const { waitUntil } = require('@vercel/functions');
    waitUntil(Sentry.flush(2000));
  } catch {
    // Not inside a Vercel invocation (local, tests): the SDK sends on its own.
  }
}

/** Waits for pending reports; used at the end of queue jobs. */
async function flush(timeoutMs = 2000) {
  if (!Sentry) return;
  try {
    await Sentry.flush(timeoutMs);
  } catch {
    // Monitoring must never fail the job.
  }
}

const isEnabled = () => Boolean(Sentry);

/** Test hook: route reports to a stub SDK (or null to turn monitoring off). */
function setSdkForTests(stub) {
  Sentry = stub;
  lastSent.clear();
}

module.exports = { init, captureLog, captureException, flush, isEnabled, pickContext, scrubEvent, setSdkForTests };
