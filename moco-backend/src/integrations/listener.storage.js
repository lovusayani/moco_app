'use strict';

const crypto = require('crypto');
const storage = require('./storage');
const { LISTENER_PHOTOS } = require('../utils/constants');

/**
 * Listener profile photos — the listener-specific path scheme and checks
 * over the shared Supabase Storage client in storage.js. Same guarantees as
 * chat.storage.js and feed.storage.js: the service-role key lives only in
 * storage.js, every upload path is minted here (never accepted from the
 * client), and every read is a short-lived signed URL against the private
 * `listener-media` bucket.
 */

const isConfigured = storage.isConfigured;

const EXTENSIONS = Object.freeze({
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
});

/** `<user-id>/<timestamp>_<random>.<ext>` — scoped to the uploader so
 * ownership is a prefix check, random so paths cannot be guessed. */
function buildPath(userId, mimeType) {
  const ext = EXTENSIONS[mimeType];
  if (!ext) throw new Error('unsupported_mime');
  return `${userId}/${Date.now()}_${crypto.randomBytes(16).toString('hex')}.${ext}`;
}

function pathBelongsToUser(path, userId) {
  return typeof path === 'string' && path.startsWith(`${userId}/`) && !path.includes('..');
}

/** The MIME type a minted path represents, from its extension — never from
 * the request body. Null for anything this module did not mint. */
function mimeTypeForPath(path) {
  const dot = typeof path === 'string' ? path.lastIndexOf('.') : -1;
  if (dot < 0) return null;
  const ext = path.slice(dot + 1).toLowerCase();
  const match = Object.entries(EXTENSIONS).find(([, candidate]) => candidate === ext);
  return match ? match[0] : null;
}

const createUploadUrl = ({ userId, mimeType }) =>
  storage.createUploadUrl(LISTENER_PHOTOS.bucket, buildPath(userId, mimeType));

const createViewUrl = (path) =>
  storage.createViewUrl(LISTENER_PHOTOS.bucket, path, {
    expiresInSeconds: LISTENER_PHOTOS.viewUrlSeconds,
  });

const statObject = (path) => storage.statObject(LISTENER_PHOTOS.bucket, path);

const remove = (path) => storage.remove(LISTENER_PHOTOS.bucket, path);

module.exports = {
  isConfigured,
  buildPath,
  pathBelongsToUser,
  mimeTypeForPath,
  createUploadUrl,
  createViewUrl,
  statObject,
  remove,
};
