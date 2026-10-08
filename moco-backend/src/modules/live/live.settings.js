'use strict';

const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const logger = require('../../utils/logger');

/**
 * Moco Live settings — admin-managed, stored in app_settings under 'live'
 * (the same key → JSON table as the login background). Everything here is
 * presentation and curation; nothing is secret, and nothing here can relax
 * the provider's geobans (those are applied in live.service.list() for every
 * request, with no setting that reaches them).
 *
 * Until the admin saves, DEFAULTS apply. Stored values are merged over the
 * defaults field by field, so settings added later get their default.
 */

const KEY = 'live';
const MAX_LIST = 200;

const OPTIONS = Object.freeze({
  provider: ['stripcash'],
  status: ['public', 'any'],
  layout: ['grid', 'large', 'compact', 'mixed'],
  aspect: ['portrait', 'square', 'landscape', 'wide'],
  density: ['comfortable', 'cozy', 'compact'],
  radius: ['none', 'small', 'medium', 'large'],
  selectionMode: ['all', 'selected', 'all_except_blocked'],
  sort: ['default', 'viewers', 'favorites', 'featured', 'hd'],
  clickBehavior: ['internal_player', 'provider'],
  cardFields: ['snapshot', 'avatar', 'liveBadge', 'username', 'viewers', 'country', 'languages', 'favorites', 'hdBadge', 'tags', 'goal'],
});

const DEFAULTS = Object.freeze({
  enabled: true,
  provider: 'stripcash',
  requireAgeConfirmation: true,
  pageSize: 24,
  status: 'public',
  preferredLanguage: null,
  preferredCountry: null,
  preferredTag: null,
  layout: {
    preset: 'grid',
    columns: { mobile: 2, tablet: 3, desktop: 4 },
    aspect: 'portrait',
    density: 'comfortable',
    radius: 'medium',
  },
  card: {
    snapshot: true,
    avatar: false,
    liveBadge: true,
    username: true,
    viewers: true,
    country: true,
    languages: false,
    favorites: false,
    hdBadge: true,
    tags: false,
    goal: false,
  },
  selection: { mode: 'all', featured: [], hidden: [], selected: [] },
  sort: 'default',
  clickBehavior: 'internal_player',
});

const username = z.string().trim().min(1).max(128).regex(/^[A-Za-z0-9_.-]+$/, 'not a valid model username');
const usernames = z
  .array(username)
  .max(MAX_LIST, `at most ${MAX_LIST} models`)
  .transform((list) => [...new Set(list)]);
const optionalCode = (re) =>
  z
    .union([z.string().trim().toLowerCase().regex(re), z.literal(''), z.null()])
    .transform((v) => (v ? v : null));

/** The full settings document, as the admin saves it. Unknown keys are dropped. */
const schema = z.object({
  enabled: z.boolean(),
  provider: z.enum(OPTIONS.provider),
  requireAgeConfirmation: z.boolean(),
  pageSize: z.number().int().min(6).max(60),
  status: z.enum(OPTIONS.status),
  preferredLanguage: optionalCode(/^[a-z]{2,3}$/),
  preferredCountry: optionalCode(/^[a-z]{2}$/),
  preferredTag: optionalCode(/^[a-z0-9][a-z0-9/_-]{0,63}$/),
  layout: z.object({
    preset: z.enum(OPTIONS.layout),
    columns: z.object({
      mobile: z.number().int().min(1).max(3),
      tablet: z.number().int().min(2).max(4),
      desktop: z.number().int().min(2).max(6),
    }),
    aspect: z.enum(OPTIONS.aspect),
    density: z.enum(OPTIONS.density),
    radius: z.enum(OPTIONS.radius),
  }),
  card: z.object(Object.fromEntries(OPTIONS.cardFields.map((f) => [f, z.boolean()]))),
  selection: z.object({
    mode: z.enum(OPTIONS.selectionMode),
    featured: usernames,
    hidden: usernames,
    selected: usernames,
  }),
  sort: z.enum(OPTIONS.sort),
  clickBehavior: z.enum(OPTIONS.clickBehavior),
});

const isObj = (v) => v && typeof v === 'object' && !Array.isArray(v);

/** Deep-merges stored values over the defaults, then keeps only valid fields. */
function merge(stored) {
  const out = JSON.parse(JSON.stringify(DEFAULTS));
  const walk = (target, source) => {
    for (const [k, v] of Object.entries(source || {})) {
      if (!(k in target)) continue;
      if (isObj(target[k]) && isObj(v)) walk(target[k], v);
      else target[k] = v;
    }
  };
  if (isObj(stored)) walk(out, stored);
  const parsed = schema.safeParse(out);
  if (parsed.success) return parsed.data;
  // A stored value that no longer validates falls back to its default rather
  // than breaking Live; the age gate is never turned off by a bad value.
  logger.warn({ issues: parsed.error.issues.length }, 'stored live settings partly invalid; using defaults there');
  const fixed = JSON.parse(JSON.stringify(out));
  for (const issue of parsed.error.issues) {
    let t = fixed;
    let d = DEFAULTS;
    const path = issue.path.filter((p) => typeof p === 'string');
    for (let i = 0; i < path.length - 1; i += 1) {
      t = t[path[i]];
      d = d[path[i]];
    }
    const last = path[path.length - 1];
    if (t && d && last in d) t[last] = JSON.parse(JSON.stringify(d[last]));
  }
  const second = schema.safeParse(fixed);
  return second.success ? second.data : JSON.parse(JSON.stringify(DEFAULTS));
}

/** Current settings (defaults merged in). Never throws. */
async function read() {
  try {
    const { rows } = await query('SELECT value, updated_at FROM app_settings WHERE key = $1', [KEY]);
    const settings = merge(rows[0]?.value);
    // Only an explicit false turns the age gate off.
    if (rows[0]?.value?.requireAgeConfirmation !== false) settings.requireAgeConfirmation = true;
    return { ...settings, updatedAt: rows[0]?.updated_at ?? null };
  } catch (err) {
    logger.warn({ err: err.message }, 'live settings unavailable; using defaults');
    return { ...JSON.parse(JSON.stringify(DEFAULTS)), updatedAt: null };
  }
}

/** Validates and stores the whole document (audited in the same transaction). */
async function save(input, admin, audit) {
  const next = schema.parse(input);
  const previous = await read();
  await withTransaction(async (client) => {
    await client.query(
      `INSERT INTO app_settings (key, value, updated_at, updated_by) VALUES ($1, $2, now(), $3)
       ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by`,
      [KEY, JSON.stringify(next), admin.id],
    );
    const changed = Object.keys(next).filter((k) => JSON.stringify(next[k]) !== JSON.stringify(previous[k]));
    await audit.record(client, {
      admin,
      action: 'settings.live.update',
      targetType: 'setting',
      targetId: KEY,
      metadata: {
        changed,
        enabled: next.enabled,
        featured: next.selection.featured.length,
        hidden: next.selection.hidden.length,
        selected: next.selection.selected.length,
      },
    });
  });
  return read();
}

/**
 * What the app needs to render Live (no curation lists, nothing secret):
 * enabled, the age gate, page size, layout, card fields, sort and click
 * behaviour.
 */
function clientView(settings) {
  return {
    requireAgeConfirmation: settings.requireAgeConfirmation,
    pageSize: settings.pageSize,
    layout: settings.layout,
    card: settings.card,
    sort: settings.sort,
    clickBehavior: settings.clickBehavior,
  };
}

module.exports = { KEY, DEFAULTS, OPTIONS, MAX_LIST, schema, merge, read, save, clientView };
