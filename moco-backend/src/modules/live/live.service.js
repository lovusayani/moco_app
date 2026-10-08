'use strict';

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

/** A model counts as online if the last sync that saw it is this recent. */
const ONLINE_WINDOW_SECONDS = 60;
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
         goal_message, goal_needed, goal_earned, provider_rank, metadata, last_seen_at, last_synced_at)
       SELECT m.provider, m."externalId", m.username, m."avatarUrl", m."snapshotUrl", m."popularSnapshotUrl",
              m."thumbUrl", m."clickUrl", m.country,
              ARRAY(SELECT jsonb_array_elements_text(m.languages)), m.gender, m."broadcastGender",
              ARRAY(SELECT jsonb_array_elements_text(m.tags)), m."viewersCount", m."favoritedCount",
              m."isHd", m."isVr", m.status, m.geobans,
              ARRAY(SELECT jsonb_array_elements_text(m."blockedCountries")),
              ARRAY(SELECT jsonb_array_elements_text(m."blockedRegions")),
              ARRAY(SELECT jsonb_array_elements_text(m."blockedRegionCountries")),
              ARRAY(SELECT jsonb_array_elements_text(m."blockedLanguages")),
              m."goalMessage", m."goalNeeded", m."goalEarned", m."providerRank", m.metadata, $2, $2
         FROM jsonb_to_recordset($1::jsonb) AS m(
              provider text, "externalId" bigint, username text, "avatarUrl" text, "snapshotUrl" text,
              "popularSnapshotUrl" text, "thumbUrl" text, "clickUrl" text, country text, languages jsonb,
              gender text, "broadcastGender" text, tags jsonb, "viewersCount" int, "favoritedCount" int,
              "isHd" boolean, "isVr" boolean, status text, geobans jsonb, "blockedCountries" jsonb,
              "blockedRegions" jsonb, "blockedRegionCountries" jsonb, "blockedLanguages" jsonb,
              "goalMessage" text, "goalNeeded" int, "goalEarned" int, "providerRank" int, metadata jsonb)
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
         provider_rank = EXCLUDED.provider_rank, metadata = EXCLUDED.metadata,
         last_seen_at = EXCLUDED.last_seen_at, last_synced_at = EXCLUDED.last_synced_at, updated_at = now()`,
      [JSON.stringify(batch), seenAt],
    );
  }
}

/**
 * One sync: fetch the provider's online list, upsert it, and mark every
 * stored model that was not in it offline. Never throws for provider
 * trouble: a failed or rate-limited fetch leaves the stored data as it was.
 */
async function sync() {
  if (!stripcash.isConfigured()) return { status: 'not_configured' };

  let result;
  try {
    result = await stripcash.fetchOnlineModels();
  } catch (err) {
    if (err.code === 'rate_limited') return { status: 'rate_limited' };
    stripcash.logFailure(err, 'sync');
    await recordState({ last_sync_at: new Date(), last_sync_ok: false, last_sync_error: err.code || 'error' }).catch(() => {});
    return { status: 'failed', error: err.code || 'error' };
  }

  const seenAt = new Date();
  await upsertModels(result.models, seenAt);
  const { rowCount: wentOffline } = await query(
    `UPDATE live_models SET status = 'offline', updated_at = now()
      WHERE provider = $1 AND last_seen_at < $2 AND status <> 'offline'`,
    [PROVIDER, seenAt],
  );
  await recordState({
    last_sync_at: seenAt,
    last_sync_ok: true,
    last_sync_error: null,
    last_count: result.count,
    last_total: result.total,
  });
  logger.info({ provider: PROVIDER, models: result.models.length, wentOffline }, 'live models synced');
  return { status: 'synced', models: result.models.length, count: result.count, total: result.total, wentOffline };
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

const SORTS = Object.freeze({
  default: 'provider_rank ASC NULLS LAST, id ASC',
  viewers: 'viewers_count DESC, provider_rank ASC NULLS LAST, id ASC',
  favorites: 'favorited_count DESC, provider_rank ASC NULLS LAST, id ASC',
  hd: 'is_hd DESC, provider_rank ASC NULLS LAST, id ASC',
});

/** The client-facing shape. Never includes the click URL, geobans or metadata. */
function serialize(row) {
  return {
    id: Number(row.id),
    provider: row.provider,
    username: row.username,
    avatarUrl: row.avatar_url,
    snapshotUrl: row.snapshot_url,
    thumbnailUrl: row.thumb_url,
    country: row.country,
    languages: row.languages,
    gender: row.gender,
    broadcastGender: row.broadcast_gender,
    tags: row.tags,
    viewers: row.viewers_count,
    favorites: row.favorited_count,
    isHd: row.is_hd,
    isVr: row.is_vr,
    goal:
      row.goal_needed > 0 || row.goal_message
        ? { message: row.goal_message, needed: row.goal_needed, earned: row.goal_earned }
        : null,
  };
}

/**
 * Public, online models for one viewer. Geobans are always applied.
 * Filters: language, country, tag. Sorts: SORTS keys.
 */
async function list(viewer, { limit = 24, offset = 0, language, country, tag, sort = 'default' } = {}) {
  const params = [PROVIDER, ONLINE_WINDOW_SECONDS];
  const where = [
    'provider = $1',
    `status = 'public'`,
    'last_seen_at > now() - make_interval(secs => $2)',
    geobanClause(viewer, params),
  ];
  if (language) {
    params.push(language);
    where.push(`$${params.length}::text = ANY(languages)`);
  }
  if (country) {
    params.push(country);
    where.push(`country = $${params.length}`);
  }
  if (tag) {
    params.push(tag);
    where.push(`$${params.length}::text = ANY(tags)`);
  }
  params.push(limit, offset);
  const { rows } = await query(
    `SELECT id, provider, username, avatar_url, snapshot_url, thumb_url, country, languages, gender,
            broadcast_gender, tags, viewers_count, favorited_count, is_hd, is_vr,
            goal_message, goal_needed, goal_earned
       FROM live_models
      WHERE ${where.join(' AND ')}
      ORDER BY ${SORTS[sort] || SORTS.default}
      LIMIT $${params.length - 1} OFFSET $${params.length}`,
    params,
  );
  return rows.map(serialize);
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
  cleanup,
  serialize,
};
