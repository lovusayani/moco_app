'use strict';

const crypto = require('crypto');
const { createClient } = require('@supabase/supabase-js');
const env = require('../config/env');
const { CHAT_MEDIA } = require('../utils/constants');

/**
 * Photo-message storage: Supabase Storage, used only as an object store.
 *
 * The service-role key lives here and nowhere else — Flutter never receives
 * it, never talks to Supabase directly, and never mints its own signed URL.
 * Every upload is authorized by this backend (path scoped to the requesting
 * user, MIME type and size checked before a URL is even issued) and every
 * read goes through a short-lived signed URL rather than a public bucket.
 */

let client = null;
if (env.supabaseStorage.url && env.supabaseStorage.serviceRoleKey) {
  client = createClient(env.supabaseStorage.url, env.supabaseStorage.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

const isConfigured = () => client !== null;

/**
 * A per-user, per-message-attempt path. Scoped under the uploader's own id so
 * an authorization check ("does this path belong to this user") is a prefix
 * check, not a database round trip.
 */
function buildPath(userId, mimeType) {
  const ext = mimeType === 'image/png' ? 'png' : mimeType === 'image/webp' ? 'webp' : 'jpg';
  const name = crypto.randomBytes(16).toString('hex');
  return `${userId}/${Date.now()}_${name}.${ext}`;
}

/** True if `path` was minted for `userId` — the authorization check for send. */
function pathBelongsToUser(path, userId) {
  return typeof path === 'string' && path.startsWith(`${userId}/`);
}

/**
 * Mints a signed upload URL for a new photo message. The client PUTs the raw
 * image bytes straight to Supabase Storage with this URL; this backend never
 * proxies the image data itself.
 */
async function createUploadUrl({ userId, mimeType }) {
  if (!isConfigured()) throw new Error('storage_not_configured');

  const path = buildPath(userId, mimeType);
  const { data, error } = await client.storage
    .from(CHAT_MEDIA.bucket)
    .createSignedUploadUrl(path);

  if (error) throw error;
  return { path, uploadUrl: data.signedUrl, token: data.token };
}

/** Mints a short-lived signed URL to view a stored photo message. */
async function createViewUrl(path, { expiresInSeconds = 3600 } = {}) {
  if (!isConfigured()) return null;

  const { data, error } = await client.storage
    .from(CHAT_MEDIA.bucket)
    .createSignedUrl(path, expiresInSeconds);

  if (error) return null;
  return data.signedUrl;
}

module.exports = { isConfigured, createUploadUrl, createViewUrl, pathBelongsToUser, buildPath };
