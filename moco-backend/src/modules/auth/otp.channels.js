'use strict';

const email = require('../../integrations/email');
const sms = require('../../integrations/sms');
const whatsapp = require('../../integrations/whatsapp');
const telegram = require('../../integrations/telegram');

/**
 * Sign-in code delivery channels.
 *
 * A channel is only a way to deliver the code. What the user proves is an
 * IDENTITY: an email address (email channel) or a phone number (sms,
 * whatsapp, telegram). Codes, cooldowns and limits are keyed by identity, so
 * asking for a code by WhatsApp after SMS replaces the SMS code rather than
 * creating a second one, and every channel ends in the same account lookup.
 *
 * Adding or swapping a provider means changing one `send` here — the auth
 * flow itself does not change.
 */

const EMAIL = /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;
const E164 = /^\+[1-9]\d{7,14}$/;

/** Trimmed and lower-cased. Rejects anything that is not a plain address. */
function normalizeEmail(raw) {
  const value = String(raw ?? '').trim().toLowerCase();
  if (value.length > 254 || !EMAIL.test(value)) return null;
  const [local, domain] = value.split('@');
  if (local.length > 64 || !domain.includes('.')) return null;
  return value;
}

/** E.164 only (+919876543210) — what the app sends after its country prefix. */
function normalizePhone(raw) {
  const value = String(raw ?? '').replace(/[\s()-]/g, '');
  return E164.test(value) ? value : null;
}

const CHANNELS = Object.freeze({
  email: {
    identity: 'email',
    normalize: normalizeEmail,
    isConfigured: email.isConfigured,
    send: (to, code, ttl) => email.sendOtp(to, code, ttl),
  },
  sms: {
    identity: 'phone',
    normalize: normalizePhone,
    isConfigured: sms.isConfigured,
    send: (to, code) => sms.sendOtp(to, code),
  },
  whatsapp: {
    identity: 'phone',
    normalize: normalizePhone,
    isConfigured: whatsapp.isConfigured,
    send: (to, code) => whatsapp.sendOtp(to, code),
  },
  telegram: {
    identity: 'phone',
    normalize: normalizePhone,
    isConfigured: telegram.isConfigured,
    send: (to, code, ttl) => telegram.sendOtp(to, code, ttl),
  },
});

const CHANNEL_IDS = Object.freeze(Object.keys(CHANNELS));
const DEFAULT_CHANNEL = 'email';

/** For GET /api/config: what the sign-in screen may offer. */
function availability() {
  return CHANNEL_IDS.map((id) => ({
    id,
    identity: CHANNELS[id].identity,
    available: Boolean(CHANNELS[id].isConfigured()),
  }));
}

module.exports = { CHANNELS, CHANNEL_IDS, DEFAULT_CHANNEL, availability, normalizeEmail, normalizePhone };
