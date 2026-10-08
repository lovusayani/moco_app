'use strict';

const { query } = require('../../config/db');
const logger = require('../../utils/logger');

/**
 * Moco Live settings, stored in app_settings under 'live' (the same
 * admin-managed key → JSON table as the login background). Not editable from
 * the console yet; until a row exists the defaults below apply.
 *
 *   enabled                 — Live can be switched off without removing the
 *                             provider credentials.
 *   requireAgeConfirmation  — the app asks for an 18+ confirmation the first
 *                             time a user opens Live. Default ON. Independent
 *                             of sign-in: it gates Live only.
 */

const KEY = 'live';

const DEFAULTS = Object.freeze({
  enabled: true,
  requireAgeConfirmation: true,
});

/** Current settings; falls back to the defaults if the row is missing or unreadable. */
async function read() {
  try {
    const { rows } = await query('SELECT value FROM app_settings WHERE key = $1', [KEY]);
    const stored = rows[0]?.value && typeof rows[0].value === 'object' ? rows[0].value : {};
    return {
      enabled: typeof stored.enabled === 'boolean' ? stored.enabled : DEFAULTS.enabled,
      // Only an explicit false turns the age gate off; anything else keeps it on.
      requireAgeConfirmation: stored.requireAgeConfirmation !== false,
    };
  } catch (err) {
    logger.warn({ err: err.message }, 'live settings unavailable; using defaults');
    return { ...DEFAULTS };
  }
}

module.exports = { KEY, DEFAULTS, read };
