'use strict';

const crypto = require('crypto');
const { query } = require('../../config/db');
const { redis } = require('../../config/redis');
const stripcash = require('../../integrations/stripcash');
const logger = require('../../utils/logger');

/**
 * Moco Live: a mirror of the provider's online-model list (Stripcash
 * aggregator API), stored in live_models and served to clients with the
 * provider's geobans enforced.
 *
 *   sync()     — one fetch + upsert; run every ~30 s while Live is in use
 *   list()     — the listing for one viewer (geobans always applied)
 *   cleanup()  — provider-reported deletions + the 30-day absence rule
 */

const PROVIDER = stripcash.PROVIDER;

/**
 * The online set is the latest successful sync's snapshot; it is trusted for
 * this long. If syncs stop (provider down), the listing empties rather than
 * showing a stale list.
 */
const ONLINE_WINDOW_SECONDS = 90;
/** last_seen_at only feeds the 30-day absence rule, so an online model's row
 * is touched for it at most this often instead of on every sync. */
const SEEN_REFRESH_MS = 6 * 3600 * 1000;

/**
 * Statuses the provider reports for online models (observed in the real
 * API). "All online" lists only these — a status the provider adds later
 * stays hidden until it is reviewed and added here.
 */
const KNOWN_STATUSES = Object.freeze(['public', 'p2p', 'private', 'groupShow', 'virtualPrivate', 'p2pVoice']);
/** A listing request triggers a sync itself when the data is older than this. */
const STALE_AFTER_SECONDS = 45;
/** Provider terms: remove everything about a model absent this long. */
const ABSENT_RETENTION_DAYS = 30;
/** Someone browsed Live recently: keep the 30-second sync chain running. */
const DEMAND_KEY = 'live:demand';
const DEMAND_TTL_SECONDS = 10 * 60;

const UPSERT_BATCH = 500;

// --- sync -------------------------------------------------------------------

async function recordState(fields) {
  const cols = Object.keys(fields);
  await query(
    `INSERT INTO live_provider_state (provider, ${cols.join(', ')}, updated_at)
     VALUES ($1, ${cols.map((_, i) => `$${i + 2}`).join(', ')}, now())
     ON CONFLICT (provider) DO UPDATE SET
       ${cols.map((c) => `${c} = EXCLUDED.${c}`).join(', ')}, updated_at = now()`,
    [PROVIDER, ...cols.map((c) => fields[c])],
  );
}

async function getState() {
  const { rows } = await query('SELECT * FROM live_provider_state WHERE provider = $1', [PROVIDER]);
  return rows[0] || null;
}

/** Upserts normalized models (by provider + username) as seen at `seenAt`. */
async function upsertModels(models, seenAt) {
  for (let i = 0; i < models.length; i += UPSERT_BATCH) {
    const batch = models.slice(i, i + UPSERT_BATCH);
    await query(
      `INSERT INTO live_models (
         provider, external_id, username, avatar_url, snapshot_url, popular_snapshot_url, thumb_url, click_url,
         country, languages, gender, broadcast_gender, tags, viewers_count, favorited_count, is_hd, is_vr, status,
         geobans, blocked_countries, blocked_regions, blocked_region_countries, blocked_languages,
         goal_message, goal_needed, goal_earned, provider_rank, metadata, content_hash, last_seen_at, last_synced_at)
       SELECT m.provider, m."externalId", m.username, m."avatarUrl", m."snapshotUrl", m."popularSnapshotUrl",
              m."thumbUrl", m."clickUrl", m.country,
              ARRAY(SELECT jsonb_array_elements_text(m.languages)), m.gender, m."broadcastGender",
              ARRAY(SELECT jsonb_array_elements_text(m.tags)), m."viewersCount", m."favoritedCount",
              m."isHd", m."isVr", m.status, m.geobans,
              ARRAY(SELECT jsonb_array_elements_text(m."blockedCountries")),
              ARRAY(SELECT jsonb_array_elements_text(m."blockedRegions")),
              ARRAY(SELECT jsonb_array_elements_text(m."blockedRegionCountries")),
              ARRAY(SELECT jsonb_array_elements_text(m."blockedLanguages")),
              m."goalMessage", m."goalNeeded", m."goalEarned", m."providerRank", m.metadata, m."contentHash", $2, $2
         FROM jsonb_to_recordset($1::jsonb) AS m(
              provider text, "externalId" bigint, username text, "avatarUrl" text, "snapshotUrl" text,
              "popularSnapshotUrl" text, "thumbUrl" text, "clickUrl" text, country text, languages jsonb,
              gender text, "broadcastGender" text, tags jsonb, "viewersCount" int, "favoritedCount" int,
              "isHd" boolean, "isVr" boolean, status text, geobans jsonb, "blockedCountries" jsonb,
              "blockedRegions" jsonb, "blockedRegionCountries" jsonb, "blockedLanguages" jsonb,
              "goalMessage" text, "goalNeeded" int, "goalEarned" int, "providerRank" int, metadata jsonb, "contentHash" text)
       ON CONFLICT (provider, username) DO UPDATE SET
         external_id = EXCLUDED.external_id, avatar_url = EXCLUDED.avatar_url,
         snapshot_url = EXCLUDED.snapshot_url, popular_snapshot_url = EXCLUDED.popular_snapshot_url,
         thumb_url = EXCLUDED.thumb_url, click_url = EXCLUDED.click_url, country = EXCLUDED.country,
         languages = EXCLUDED.languages, gender = EXCLUDED.gender, broadcast_gender = EXCLUDED.broadcast_gender,
         tags = EXCLUDED.tags, viewers_count = EXCLUDED.viewers_count, favorited_count = EXCLUDED.favorited_count,
         is_hd = EXCLUDED.is_hd, is_vr = EXCLUDED.is_vr, status = EXCLUDED.status, geobans = EXCLUDED.geobans,
         blocked_countries = EXCLUDED.blocked_countries, blocked_regions = EXCLUDED.blocked_regions,
         blocked_region_countries = EXCLUDED.blocked_region_countries,
         blocked_languages = EXCLUDED.blocked_languages, goal_message = EXCLUDED.goal_message,
         goal_needed = EXCLUDED.goal_needed, goal_earned = EXCLUDED.goal_earned,
         provider_rank = EXCLUDED.provider_rank, metadata = EXCLUDED.metadata, content_hash = EXCLUDED.content_hash,
         last_seen_at = EXCLUDED.last_seen_at, last_synced_at = EXCLUDED.last_synced_at, updated_at = now()`,
      [JSON.stringify(batch), seenAt],
    );
  }
}

/**
 * The fields that make a model's row worth rewriting: identity, images (with
 * the response-wide snapshot timestamp templated out), tags, status, geobans,
 * goal text. Rank, viewers, favorites and goal progress change on nearly every
 * fetch and live in the per-sync snapshot instead.
 */
function contentHash(m) {
  const material = [
    m.externalId, m.username, m.avatarUrl, m.snapshotUrl, m.thumbUrl, m.clickUrl, m.country, m.languages,
    m.gender, m.broadcastGender, m.tags, m.isHd, m.isVr, m.status, m.blockedCountries, m.blockedRegions,
    m.blockedLanguages, m.goalMessage,
  ];
  return crypto.createHash('sha1').update(JSON.stringify(material)).digest('hex');
}

/**
 * One sync: fetch the provider's online list and write only what changed.
 *
 *   - rows: inserted when new, rewritten only when their content hash
 *     changed; unchanged rows are not written (last_seen_at, used only by the
 *     30-day rule, is refreshed in one statement at most every 6 hours);
 *   - models absent from the list: marked offline in one statement;
 *   - rank / viewers / favorites / goal progress for every online model, and
 *     the snapshot image timestamp: one JSON document on the provider state
 *     row, written once.
 *
 * Never throws for provider trouble: a failed or rate-limited fetch leaves
 * the stored data as it was.
 */
async function sync() {
  if (!stripcash.isConfigured()) return { status: 'not_configured' };

  let result;
  const startedAt = Date.now();
  try {
    result = await stripcash.fetchOnlineModels();
  } catch (err) {
    if (err.code === 'rate_limited') return { status: 'rate_limited' };
    stripcash.logFailure(err, 'sync');
    await recordState({ last_sync_at: new Date(), last_sync_ok: false, last_sync_error: err.code || 'error' }).catch(() => {});
    return { status: 'failed', error: err.code || 'error' };
  }
  const fetchMs = Date.now() - startedAt;

  const seenAt = new Date();
  const { rows: stored } = await query('SELECT username, content_hash, last_seen_at FROM live_models WHERE provider = $1', [PROVIDER]);
  const existing = new Map(stored.map((r) => [r.username, r]));

  const changed = [];
  const touch = [];
  let inserted = 0;
  for (const m of result.models) {
    m.contentHash = contentHash(m);
    const row = existing.get(m.username);
    if (!row) inserted += 1;
    if (!row || row.content_hash !== m.contentHash) changed.push(m);
    else if (seenAt - new Date(row.last_seen_at) > SEEN_REFRESH_MS) touch.push(m.username);
  }

  await upsertModels(changed, seenAt);
  if (touch.length) {
    await query(
      'UPDATE live_models SET last_seen_at = $2, last_synced_at = $2 WHERE provider = $1 AND username = ANY($3::text[])',
      [PROVIDER, seenAt, touch],
    );
  }
  const online = result.models.map((m) => m.username);
  const { rowCount: wentOffline } = await query(
    `UPDATE live_models SET status = 'offline', updated_at = now()
      WHERE provider = $1 AND status <> 'offline' AND NOT (username = ANY($2::text[]))`,
    [PROVIDER, online],
  );

  // username → [rank, viewers, favorites, goal needed, goal earned]
  const snapshot = {};
  for (const m of result.models) {
    snapshot[m.username] = [m.providerRank, m.viewersCount, m.favoritedCount, m.goalNeeded ?? 0, m.goalEarned ?? 0];
  }
  await recordState({
    last_sync_at: seenAt,
    last_ok_sync_at: seenAt,
    last_sync_ok: true,
    last_sync_error: null,
    last_count: result.count,
    last_total: result.total,
    live_snapshot: JSON.stringify(snapshot),
    snapshot_ts: result.snapshotTs,
  });

  const counts = {
    models: result.models.length,
    inserted,
    updated: changed.length - inserted,
    unchanged: result.models.length - changed.length,
    seenRefreshed: touch.length,
    wentOffline,
  };
  logger.info({ provider: PROVIDER, fetchMs, ...counts }, 'live models synced');
  return { status: 'synced', count: result.count, total: result.total, fetchMs, ...counts };
}

/** Marks that someone is browsing Live, so the sync chain keeps going. */
async function noteDemand() {
  await redis.set(DEMAND_KEY, '1', 'EX', DEMAND_TTL_SECONDS).catch(() => {});
}

async function hasDemand() {
  return (await redis.exists(DEMAND_KEY).catch(() => 0)) === 1;
}

/**
 * Called by the listing: if the stored list is older than STALE_AFTER_SECONDS
 * (the sync chain was idle), sync now so the first viewer does not get an
 * empty or stale page. The provider rate slot still applies — if another
 * instance just synced or is syncing, this returns without waiting.
 */
async function syncIfStale() {
  if (!stripcash.isConfigured()) return { status: 'not_configured' };
  const state = await getState();
  const age = state?.last_sync_at ? (Date.now() - new Date(state.last_sync_at).getTime()) / 1000 : Infinity;
  if (age < STALE_AFTER_SECONDS) return { status: 'fresh' };
  return sync();
}

// --- viewer / geobans -------------------------------------------------------

const UNKNOWN_COUNTRIES = new Set(['', 'xx', 't1', 'a1', 'a2', 'o1']);

/**
 * The viewer's location and languages, from the edge's geolocation headers
 * (Cloudflare first — api.lovcamx.online is proxied — then Vercel) and the
 * Accept-Language header. Unknown values stay null; list() then fails closed.
 */
function viewerFromRequest(req) {
  const h = (name) => String(req.get(name) || '').trim().toLowerCase();
  const country = [h('cf-ipcountry'), h('x-vercel-ip-country')].find((c) => /^[a-z]{2}$/.test(c) && !UNKNOWN_COUNTRIES.has(c)) || null;
  const regionRaw = h('cf-region-code') || h('x-vercel-ip-country-region');
  const region = country && /^[a-z0-9]{1,3}$/.test(regionRaw) ? regionRaw : null;
  const languages = [
    ...new Set(
      String(req.get('accept-language') || '')
        .split(',')
        .map((part) => part.split(';')[0].trim().toLowerCase().split('-')[0])
        .filter((tag) => /^[a-z]{2,3}$/.test(tag)),
    ),
  ].slice(0, 10);
  return { country, region, languages };
}

/**
 * SQL that hides every model geobanned for this viewer. Not optional and not
 * bypassable: list() always applies it, and no parameter disables it.
 *
 *  - country known: not in blocked_countries; and either the region is known
 *    and "cc.region" is not blocked, or the region is unknown and the country
 *    has no regional bans at all (fail closed).
 *  - country unknown: only models with no country or regional bans.
 *  - languages: no overlap between the viewer's Accept-Language languages
 *    and blocked_languages.
 */
function geobanClause(viewer, params) {
  const p = (value) => {
    params.push(value);
    return `$${params.length}`;
  };
  const clauses = [];
  if (viewer.country) {
    const c = p(viewer.country);
    clauses.push(`NOT (${c}::text = ANY(blocked_countries))`);
    if (viewer.region) {
      clauses.push(`NOT ((${c}::text || '.' || ${p(viewer.region)}::text) = ANY(blocked_regions))`);
    } else {
      clauses.push(`NOT (${c}::text = ANY(blocked_region_countries))`);
    }
  } else {
    clauses.push('cardinality(blocked_countries) = 0', 'cardinality(blocked_regions) = 0');
  }
  if (viewer.languages.length) clauses.push(`NOT (blocked_languages && ${p(viewer.languages)}::text[])`);
  return clauses.join(' AND ');
}

// --- listing ----------------------------------------------------------------

const RANK = 'rank_now ASC NULLS LAST, id ASC';
const SORTS = Object.freeze({
  default: RANK,
  viewers: `viewers_now DESC, ${RANK}`,
  favorites: `favorites_now DESC, ${RANK}`,
  hd: `is_hd DESC, ${RANK}`,
  featured: RANK,
});

/**
 * Stored models joined to the latest successful sync's snapshot: only models
 * in it (online now) are returned, with their current rank / viewers /
 * favorites / goal progress and the snapshot timestamp. `$1` is the provider
 * and `$2` the freshness window in seconds.
 */
/**
 * The latest fresh snapshot as rows (username, value, ts). It is expanded
 * once with jsonb_each and hash-joined: looking keys up in the snapshot per
 * stored row instead re-reads the whole (TOASTed) snapshot for every row,
 * which took ~100 s per listing with the real ~12k-model list.
 */
const SNAPSHOT_ROWS = `
  SELECT e.key AS username, e.value AS v, p.snapshot_ts AS ts
    FROM live_provider_state p, jsonb_each(p.live_snapshot) e
   WHERE p.provider = $1 AND p.last_ok_sync_at > now() - make_interval(secs => $2)`;

const ONLINE_MODELS = `
  SELECT m.*, s.ts AS snapshot_ts,
         (s.v ->> 0)::int AS rank_now,
         (s.v ->> 1)::int AS viewers_now,
         (s.v ->> 2)::int AS favorites_now,
         (s.v ->> 3)::int AS goal_needed_now,
         (s.v ->> 4)::int AS goal_earned_now
    FROM live_models m
    JOIN (${SNAPSHOT_ROWS}) s ON s.username = m.username
   WHERE m.provider = $1`;

/** Fills the stored '{ts}' placeholder with the current snapshot timestamp. */
const fillTs = (url, ts) => (url && url.includes('{ts}') ? (ts ? url.split('{ts}').join(String(ts)) : null) : url);

/**
 * The client-facing shape. Never includes geobans, metadata or anything
 * secret. The provider link (clickUrl, which carries the affiliate tracking
 * id) is included only when the admin chose "open provider destination".
 */
function serialize(row, { featured = [], clickBehavior = 'internal_player' } = {}) {
  const goalNeeded = row.goal_needed_now ?? row.goal_needed;
  const goalEarned = row.goal_earned_now ?? row.goal_earned;
  return {
    id: Number(row.id),
    provider: row.provider,
    username: row.username,
    avatarUrl: row.avatar_url,
    snapshotUrl: fillTs(row.snapshot_url, row.snapshot_ts),
    thumbnailUrl: row.thumb_url,
    country: row.country,
    languages: row.languages,
    gender: row.gender,
    broadcastGender: row.broadcast_gender,
    tags: row.tags,
    viewers: row.viewers_now ?? row.viewers_count,
    favorites: row.favorites_now ?? row.favorited_count,
    isHd: row.is_hd,
    isVr: row.is_vr,
    status: row.status,
    featured: featured.includes(row.username),
    goal:
      goalNeeded > 0 || row.goal_message
        ? { message: row.goal_message, needed: goalNeeded, earned: goalEarned }
        : null,
    ...(clickBehavior === 'provider' ? { destinationUrl: row.click_url } : {}),
  };
}

const NO_CURATION = Object.freeze({
  status: 'public',
  selection: { mode: 'all', featured: [], hidden: [], selected: [] },
  preferredLanguage: null,
  preferredCountry: null,
  preferredTag: null,
  sort: 'default',
  clickBehavior: 'internal_player',
});

/**
 * Online models for one viewer, shaped by the admin's Live settings.
 *
 * Geobans come first and are not configurable: geobanClause() is always part
 * of the WHERE, and no setting or parameter reaches it. The settings then
 * narrow (status, selection mode, hidden list) and order (featured,
 * preferred language/country/tag, sort) what is left.
 *
 * Request filters: language, country, tag. Sort: the request's, else the
 * admin's default.
 */
async function list(viewer, { limit = 24, offset = 0, language, country, tag, sort } = {}, settings = NO_CURATION) {
  const sel = settings.selection || NO_CURATION.selection;
  const params = [PROVIDER, ONLINE_WINDOW_SECONDS];
  const p = (value) => {
    params.push(value);
    return `$${params.length}`;
  };
  const where = [
    // "All online" is an explicit allowlist: unknown future statuses stay hidden.
    settings.status === 'any' ? `status = ANY(${p([...KNOWN_STATUSES])}::text[])` : `status = 'public'`,
    geobanClause(viewer, params),
  ];

  // Selection: all eligible / selected only / all except hidden.
  if (sel.mode === 'selected') where.push(`username = ANY(${p(sel.selected)}::text[])`);
  // An explicitly hidden model stays hidden in every mode — "all" included.
  if (sel.hidden.length) where.push(`NOT (username = ANY(${p(sel.hidden)}::text[]))`);

  if (language) where.push(`${p(language)}::text = ANY(languages)`);
  if (country) where.push(`country = ${p(country)}`);
  if (tag) where.push(`${p(tag)}::text = ANY(tags)`);

  const effectiveSort = SORTS[sort] ? sort : SORTS[settings.sort] ? settings.sort : 'default';
  const order = [];
  if (effectiveSort === 'featured' && sel.featured.length) {
    order.push(`array_position(${p(sel.featured)}::text[], username) ASC NULLS LAST`);
  }
  // Preferred language / country / tag: boosted, not filtered.
  const boosts = [];
  if (settings.preferredLanguage) boosts.push(`(${p(settings.preferredLanguage)}::text = ANY(languages))::int`);
  if (settings.preferredCountry) boosts.push(`(country = ${p(settings.preferredCountry)})::int`);
  if (settings.preferredTag) boosts.push(`(${p(settings.preferredTag)}::text = ANY(tags))::int`);
  if (boosts.length) order.push(`(${boosts.join(' + ')}) DESC`);
  order.push(SORTS[effectiveSort]);

  const limitParam = p(limit);
  const offsetParam = p(offset);
  const { rows } = await query(
    `SELECT id, provider, username, avatar_url, snapshot_url, thumb_url, click_url, country, languages, gender,
            broadcast_gender, tags, viewers_count, favorited_count, is_hd, is_vr, status,
            goal_message, goal_needed, goal_earned, snapshot_ts, rank_now, viewers_now, favorites_now,
            goal_needed_now, goal_earned_now
       FROM (${ONLINE_MODELS}) o
      WHERE ${where.join(' AND ')}
      ORDER BY ${order.join(', ')}
      LIMIT ${limitParam} OFFSET ${offsetParam}`,
    params,
  );
  return rows.map((row) => serialize(row, { featured: sel.featured, clickBehavior: settings.clickBehavior }));
}

/**
 * Admin search over everything stored (any status, online or not), for
 * picking featured / hidden / selected models. Admin-only; returns no
 * geoban data and is never used to build the public listing.
 */
async function searchStored({ q, limit = 30 } = {}) {
  const params = [PROVIDER, ONLINE_WINDOW_SECONDS];
  let filter = '';
  if (q) {
    params.push(`%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`);
    filter = `AND username ILIKE $${params.length}`;
  }
  params.push(limit);
  const { rows } = await query(
    `SELECT m.id, m.username, m.thumb_url, m.avatar_url, m.snapshot_url, m.status, m.country, m.last_seen_at,
            COALESCE((s.v ->> 1)::int, m.viewers_count) AS viewers_count, s.ts AS snapshot_ts,
            (s.username IS NOT NULL) AS online,
            (s.v ->> 0)::int AS rank_now
       FROM live_models m
       LEFT JOIN (${SNAPSHOT_ROWS}) s ON s.username = m.username
      WHERE m.provider = $1 ${filter.replace('username', 'm.username')}
      ORDER BY online DESC, rank_now ASC NULLS LAST, m.username ASC
      LIMIT $${params.length}`,
    params,
  );
  return rows.map((r) => ({
    id: Number(r.id),
    username: r.username,
    imageUrl: r.thumb_url || r.avatar_url || fillTs(r.snapshot_url, r.snapshot_ts),
    status: r.status,
    online: r.online,
    viewers: r.viewers_count,
    country: r.country,
    lastSeenAt: r.last_seen_at,
  }));
}

/** Counts for the admin page header. */
async function storedCounts() {
  const { rows } = await query(
    `SELECT count(*)::int AS stored,
            count(*) FILTER (WHERE s.username IS NOT NULL)::int AS online,
            count(*) FILTER (WHERE s.username IS NOT NULL AND m.status = 'public')::int AS public
       FROM live_models m
       LEFT JOIN (${SNAPSHOT_ROWS}) s ON s.username = m.username
      WHERE m.provider = $1`,
    [PROVIDER, ONLINE_WINDOW_SECONDS],
  );
  return rows[0];
}

// --- cleanup ----------------------------------------------------------------

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Provider terms: remove every stored model the provider reports deleted,
 * and every model absent from the API for 30 consecutive days. Runs daily.
 * The 30-day rule needs no API call, so it runs even when the provider is
 * unreachable or not configured.
 */
async function cleanup({ now = new Date() } = {}) {
  const { rowCount: absent } = await query(
    `DELETE FROM live_models
      WHERE provider = $1 AND last_seen_at < $2::timestamptz - make_interval(days => $3)`,
    [PROVIDER, now, ABSENT_RETENTION_DAYS],
  );
  const result = { absentRemoved: absent, deletedRemoved: 0, deletedCheck: 'skipped' };

  if (stripcash.isConfigured()) {
    const state = await getState();
    // Inclusive range; re-reading the boundary record is harmless.
    const since = state?.deleted_cursor ? new Date(state.deleted_cursor) : new Date(now.getTime() - 7 * 86400_000);
    let deleted = null;
    for (let attempt = 0; attempt < 2 && deleted === null; attempt += 1) {
      try {
        deleted = await stripcash.fetchDeletedModels({ since, until: now });
      } catch (err) {
        if (err.code === 'rate_limited' && attempt === 0) {
          await sleep(stripcash.MIN_INTERVAL_MS + 200);
          continue;
        }
        stripcash.logFailure(err, 'deleted-models check');
        result.deletedCheck = err.code || 'failed';
        break;
      }
    }
    if (deleted) {
      if (deleted.length) {
        const { rowCount } = await query('DELETE FROM live_models WHERE provider = $1 AND username = ANY($2)', [
          PROVIDER,
          deleted.map((m) => m.username),
        ]);
        result.deletedRemoved = rowCount;
      }
      const newest = deleted.reduce((max, m) => (m.deletedAt && !Number.isNaN(m.deletedAt.getTime()) && m.deletedAt > max ? m.deletedAt : max), since);
      await recordState({ deleted_cursor: newest, last_cleanup_at: now });
      result.deletedCheck = 'ok';
      result.deletedReported = deleted.length;
    }
  }
  if (result.deletedCheck !== 'ok') await recordState({ last_cleanup_at: now });

  logger.info({ provider: PROVIDER, ...result }, 'live models cleanup');
  return result;
}

module.exports = {
  ONLINE_WINDOW_SECONDS,
  KNOWN_STATUSES,
  contentHash,
  STALE_AFTER_SECONDS,
  ABSENT_RETENTION_DAYS,
  SORTS,
  sync,
  syncIfStale,
  noteDemand,
  hasDemand,
  getState,
  upsertModels,
  viewerFromRequest,
  list,
  searchStored,
  storedCounts,
  cleanup,
  serialize,
};
