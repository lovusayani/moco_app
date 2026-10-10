'use strict';

const env = require('../config/env');
const logger = require('../utils/logger');
const { redis } = require('../config/redis');

/**
 * Stripcash "Models API for aggregators" — the provider behind Moco Live.
 *
 *   GET {base}/app/models-ext/models?userId=…           online models
 *   GET {base}/app/models-ext/models/deleted?…          deleted models (≤ 90 days)
 *   Authorization: Bearer <domain API key>
 *
 * Provider rules this module enforces:
 *   - at most one request every 5 seconds — shared across every instance
 *     through a Redis slot, and across both endpoints;
 *   - images are the provider's URLs, never downloaded;
 *   - the API key never leaves this module: it is not logged, and errors
 *     carry only an HTTP status or a short code.
 *
 * Two different ids: the short API user id (STRIPCASH_API_USER_ID) goes on
 * aggregator requests only; the affiliate player id from the default link
 * (STRIPCASH_PLAYER_USER_ID) is the one the official player needs, so
 * playerConfig() exposes that one (and only it) to signed-in clients. Neither
 * is logged.
 */

const PROVIDER = 'stripcash';
const MIN_INTERVAL_MS = 5000;
const TIMEOUT_MS = 15000;
/** The full online list is ~12k models / ~36 MB; reading it can take well
 * over 15 s, and the timeout covers reading the body too. */
const MODELS_TIMEOUT_MS = 60000;
const RATE_SLOT_KEY = 'live:stripcash:rate_slot';

const isConfigured = () => Boolean(env.stripcash.apiKey && env.stripcash.apiUserId);

if (env.stripcash.usingDeprecatedUserId) {
  logger.warn('STRIPCASH_USER_ID is deprecated: set STRIPCASH_API_USER_ID (API) and STRIPCASH_PLAYER_USER_ID (player) instead');
}

class StripcashError extends Error {
  constructor(code, status) {
    super(status ? `${code} (HTTP ${status})` : code);
    this.code = code;
    this.status = status;
  }
}

/**
 * Claims the provider's single request slot for the next 5 seconds. Returns
 * false if a request (from any instance) was made less than 5 s ago.
 */
async function claimRequestSlot() {
  const ok = await redis.set(RATE_SLOT_KEY, '1', 'PX', MIN_INTERVAL_MS, 'NX');
  return ok === 'OK';
}

async function request(path, params, { timeoutMs = TIMEOUT_MS } = {}) {
  if (!isConfigured()) throw new StripcashError('not_configured');
  if (!(await claimRequestSlot())) throw new StripcashError('rate_limited');

  const url = new URL(path, env.stripcash.baseUrl);
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== '') url.searchParams.set(key, String(value));
  }

  let response;
  try {
    response = await fetch(url, {
      headers: { Authorization: `Bearer ${env.stripcash.apiKey}`, Accept: 'application/json' },
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    throw new StripcashError(err.name === 'TimeoutError' ? 'timeout' : 'network_error');
  }
  if (response.status === 401 || response.status === 403) throw new StripcashError('auth_failed', response.status);
  if (response.status === 429) throw new StripcashError('provider_rate_limited', response.status);
  if (!response.ok) throw new StripcashError('http_error', response.status);
  try {
    return await response.json();
  } catch (err) {
    // An abort while the body was still arriving is a timeout, not bad JSON.
    if (err?.name === 'TimeoutError' || err?.name === 'AbortError') throw new StripcashError('timeout');
    throw new StripcashError('bad_json', response.status);
  }
}

// --- normalization --------------------------------------------------------

const str = (v, max = 2048) => (typeof v === 'string' && v.trim() ? v.trim().slice(0, max) : null);
const int = (v) => (Number.isFinite(Number(v)) ? Math.max(0, Math.trunc(Number(v))) : 0);
const intOrNull = (v) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Math.trunc(Number(v)));
const lowerList = (v) =>
  Array.isArray(v) ? [...new Set(v.filter((x) => typeof x === 'string' && x.trim()).map((x) => x.trim().toLowerCase()))] : [];
const httpsUrl = (v) => {
  const s = str(v);
  if (!s) return null;
  try {
    const u = new URL(s);
    return u.protocol === 'https:' || u.protocol === 'http:' ? u.href : null;
  } catch {
    return null;
  }
};

/**
 * Regional bans arrive as an object keyed by country ({"us": ["ny", "va"]});
 * a flat list ("us.tx") is accepted too. Both become ['us.ny', 'us.va'].
 */
function normalizeRegions(value) {
  const out = new Set();
  if (Array.isArray(value)) {
    for (const r of value) if (typeof r === 'string' && r.includes('.')) out.add(r.trim().toLowerCase());
  } else if (value && typeof value === 'object') {
    for (const [country, regions] of Object.entries(value)) {
      const cc = country.trim().toLowerCase();
      for (const r of Array.isArray(regions) ? regions : []) {
        if (typeof r === 'string' && r.trim()) out.add(`${cc}.${r.trim().toLowerCase().replace(/^.*\./, '')}`);
      }
    }
  }
  return [...out];
}

/** Raw stream locations are never stored (provider: they change and are not
 * a stable integration point); CDN host hints are ignored too. */
const STREAM_KEY = /stream|hls|m3u8|playlist|cdn/i;
const STREAM_VALUE = /\.m3u8(\?|$)|\/hls\//i;

const KNOWN_FIELDS = new Set([
  'id', 'username', 'avatarUrl', 'popularSnapshotUrl', 'snapshotUrl', 'clickUrl', 'modelsCountry',
  'gender', 'broadcastGender', 'previewUrlThumbSmall', 'tags', 'favoritedCount', 'viewersCount',
  'broadcastVR', 'broadcastHD', 'geobans', 'status', 'goalMessage', 'neededForGoal', 'earnedForGoal', 'languages',
]);

/**
 * One provider model → the shape stored in live_models. Returns null for a
 * record without a usable username (it could never be matched or removed).
 */
function normalizeModel(raw, rank) {
  if (!raw || typeof raw !== 'object') return null;
  const username = str(raw.username, 128);
  if (!username) return null;

  const geobans = raw.geobans && typeof raw.geobans === 'object' ? raw.geobans : {};
  const blockedRegions = normalizeRegions(geobans.blockedRegions);

  const metadata = {};
  for (const [key, value] of Object.entries(raw)) {
    if (KNOWN_FIELDS.has(key) || STREAM_KEY.test(key)) continue;
    if (typeof value === 'string' && STREAM_VALUE.test(value)) continue;
    if (value === null || ['string', 'number', 'boolean'].includes(typeof value)) metadata[key] = value;
  }

  return {
    provider: PROVIDER,
    externalId: intOrNull(raw.id),
    username,
    avatarUrl: httpsUrl(raw.avatarUrl),
    snapshotUrl: httpsUrl(raw.snapshotUrl),
    popularSnapshotUrl: httpsUrl(raw.popularSnapshotUrl),
    thumbUrl: httpsUrl(raw.previewUrlThumbSmall),
    clickUrl: httpsUrl(raw.clickUrl),
    country: str(raw.modelsCountry, 8)?.toLowerCase() ?? null,
    languages: lowerList(raw.languages),
    gender: str(raw.gender, 32),
    broadcastGender: str(raw.broadcastGender, 32),
    tags: lowerList(raw.tags),
    viewersCount: int(raw.viewersCount),
    favoritedCount: int(raw.favoritedCount),
    isHd: raw.broadcastHD === true,
    isVr: raw.broadcastVR === true,
    status: str(raw.status, 32) ?? 'unknown',
    geobans: {
      blockedCountries: lowerList(geobans.blockedCountries),
      blockedRegions: geobans.blockedRegions ?? {},
      blockedLanguages: lowerList(geobans.blockedLanguages),
    },
    blockedCountries: lowerList(geobans.blockedCountries),
    blockedRegions,
    blockedRegionCountries: [...new Set(blockedRegions.map((r) => r.split('.')[0]))],
    blockedLanguages: lowerList(geobans.blockedLanguages),
    goalMessage: str(raw.goalMessage, 500),
    goalNeeded: intOrNull(raw.neededForGoal),
    goalEarned: intOrNull(raw.earnedForGoal),
    providerRank: rank,
    metadata,
  };
}

/**
 * Snapshot image URLs carry one timestamp shared by the whole response
 * (…/thumbs/<ts>/<id>), so every URL "changes" on every fetch. The dominant
 * 10-digit path segment is that timestamp; it is replaced by '{ts}' in the
 * stored URLs and kept once per sync (live_provider_state.snapshot_ts).
 */
const TS_SEGMENT = /\/(\d{10})(?=\/|$)/g;
function dominantTimestamp(models) {
  const counts = new Map();
  for (const m of models) {
    for (const match of String(m.snapshotUrl || '').matchAll(TS_SEGMENT)) {
      counts.set(match[1], (counts.get(match[1]) || 0) + 1);
    }
  }
  let best = null;
  for (const [ts, n] of counts) if (!best || n > best[1]) best = [ts, n];
  return best && best[1] >= Math.max(1, models.length / 2) ? best[0] : null;
}
const templateTs = (url, ts) => (url && ts ? url.split(`/${ts}`).join('/{ts}') : url);

/** `{ count, total, models }` → normalized models in provider (rating) order. */
function parseModelsResponse(body) {
  if (!body || typeof body !== 'object' || !Array.isArray(body.models)) {
    throw new StripcashError('bad_response');
  }
  const models = [];
  const seen = new Set();
  body.models.forEach((raw, index) => {
    const model = normalizeModel(raw, index + 1);
    if (model && !seen.has(model.username)) {
      seen.add(model.username);
      models.push(model);
    }
  });
  const snapshotTs = dominantTimestamp(models);
  if (snapshotTs) {
    for (const m of models) {
      m.snapshotUrl = templateTs(m.snapshotUrl, snapshotTs);
      m.popularSnapshotUrl = templateTs(m.popularSnapshotUrl, snapshotTs);
      for (const [k, v] of Object.entries(m.metadata)) if (typeof v === 'string') m.metadata[k] = templateTs(v, snapshotTs);
    }
  }
  return { count: int(body.count), total: int(body.total), models, snapshotTs: snapshotTs ? Number(snapshotTs) : null };
}

/** Online models, normalized. Throws StripcashError. */
async function fetchOnlineModels() {
  const body = await request('/app/models-ext/models', { userId: env.stripcash.apiUserId }, { timeoutMs: MODELS_TIMEOUT_MS });
  return parseModelsResponse(body);
}

/** Models deleted in [since, until] (RFC 3339). Throws StripcashError. */
async function fetchDeletedModels({ since, until } = {}) {
  const body = await request('/app/models-ext/models/deleted', {
    deleted_since: since ? new Date(since).toISOString() : undefined,
    deleted_until: until ? new Date(until).toISOString() : undefined,
  });
  if (!body || typeof body !== 'object' || !Array.isArray(body.models)) throw new StripcashError('bad_response');
  return body.models
    .map((m) => ({ username: str(m?.username, 128), deletedAt: m?.deletedAt ? new Date(m.deletedAt) : null, reason: str(m?.reason, 64) }))
    .filter((m) => m.username);
}

/**
 * Options for the official Stripchat player widget, per the provider docs:
 * `new StripchatPlayer({ modelName, ...PLAYER_OPTIONS, userId }).mount(el)`.
 * modelName is the model the viewer picked.
 */
const PLAYER_OPTIONS = Object.freeze({
  strict: 1,
  autoplay: 'playButton',
  volumeControl: 1,
  fullscreen: 1,
  thumbFit: 'smart',
  usePreroll: 2,
});

/** The configured player script, if it is an https URL. */
function playerScriptUrl() {
  const raw = (env.stripcash.playerScriptUrl || '').trim();
  try {
    const url = new URL(raw);
    return url.protocol === 'https:' ? url.href : null;
  } catch {
    return null;
  }
}

/**
 * Non-secret settings for the official Stripchat player. Null — and the app
 * shows its "player not available" state — until both the default-link
 * affiliate id and the provider's script URL are configured: no guessed
 * script, no raw stream URLs.
 */
function playerConfig() {
  const scriptUrl = playerScriptUrl();
  if (!env.stripcash.playerUserId || !scriptUrl) return null;
  return {
    type: 'stripchat-player',
    userId: env.stripcash.playerUserId,
    ...PLAYER_OPTIONS,
    scriptUrl,
    // The isolated page that hosts the player, on the API's own origin
    // (src/modules/live/live.player.js). Relative to the API base URL.
    framePath: '/live/player-frame',
  };
}

/** Concise, secret-free log line for a provider failure. */
function logFailure(err, what) {
  const level = err.code === 'rate_limited' || err.code === 'not_configured' ? 'debug' : 'warn';
  logger[level]({ provider: PROVIDER, code: err.code || 'error', status: err.status }, `stripcash ${what} failed`);
}

module.exports = {
  PROVIDER,
  MIN_INTERVAL_MS,
  StripcashError,
  isConfigured,
  playerConfig,
  playerScriptUrl,
  PLAYER_OPTIONS,
  fetchOnlineModels,
  fetchDeletedModels,
  normalizeModel,
  parseModelsResponse,
  normalizeRegions,
  logFailure,
};
