'use strict';

const crypto = require('crypto');
const storage = require('./storage');
const { CHAT_MEDIA } = require('../utils/constants');

/**
 * Photo-message storage — the chat-specific path scheme and authorization
 * over the shared Supabase Storage client in storage.js. Every upload is
 * authorized by this backend (path scoped to the requesting user, MIME type
 * checked before a URL is even issued) and every read goes through a
 * short-lived signed URL rather than a public bucket.
 */

const isConfigured = storage.isConfigured;

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
  return storage.createUploadUrl(CHAT_MEDIA.bucket, buildPath(userId, mimeType));
}

/** Mints a short-lived signed URL to view a stored photo message. */
async function createViewUrl(path, options) {
  return storage.createViewUrl(CHAT_MEDIA.bucket, path, options);
}

module.exports = { isConfigured, createUploadUrl, createViewUrl, pathBelongsToUser, buildPath };
