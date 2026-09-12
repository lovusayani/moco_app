'use strict';

const crypto = require('crypto');
const storage = require('./storage');
const { FEED_MEDIA, POST_MEDIA_TYPE } = require('../utils/constants');

/**
 * Feed post media — the feed-specific path scheme and authorization over the
 * shared Supabase Storage client in storage.js. Same shape as
 * chat.storage.js and the same guarantees: the service-role key lives only in
 * storage.js, every upload path is minted here (never accepted from the
 * client), and every read is a short-lived signed URL against a private
 * bucket rather than a public object.
 */

const isConfigured = storage.isConfigured;

const EXTENSIONS = Object.freeze({
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'video/mp4': 'mp4',
  'video/quicktime': 'mov',
});

/**
 * A per-user, per-upload path: `<user-id>/<random>.<ext>`.
 *
 * Scoped under the uploader's own id so authorizing "does this path belong to
 * this user" is a prefix check rather than a database round trip — the same
 * scheme chat photos use. Random rather than sequential so one user's path
 * cannot be guessed from another's, and so a retried upload never collides
 * with the previous attempt's object.
 */
function buildPath(userId, mimeType) {
  const ext = EXTENSIONS[mimeType] ?? 'bin';
  const name = crypto.randomBytes(16).toString('hex');
  return `${userId}/${Date.now()}_${name}.${ext}`;
}

/** True if `path` was minted for `userId` — the authorization check on create. */
function pathBelongsToUser(path, userId) {
  return typeof path === 'string' && path.startsWith(`${userId}/`);
}

/**
 * The post media type a stored path represents, or null if the extension is
 * not one this backend mints.
 *
 * Post creation derives the media type from the path this way rather than
 * accepting it from the request body. The client has no say in it: the
 * extension was chosen by buildPath() from the MIME type the upload
 * authorization already validated, so deriving it here means a client cannot
 * upload a video and register it as an image (which would hand the Flutter
 * feed an <img> for an MP4 and break the item).
 */
function mediaTypeForPath(path) {
  const dot = typeof path === 'string' ? path.lastIndexOf('.') : -1;
  if (dot < 0) return null;
  const ext = path.slice(dot + 1).toLowerCase();
  for (const [mimeType, candidate] of Object.entries(EXTENSIONS)) {
    if (candidate !== ext) continue;
    return FEED_MEDIA.allowedVideoMimeTypes.includes(mimeType)
      ? POST_MEDIA_TYPE.VIDEO
      : POST_MEDIA_TYPE.IMAGE;
  }
  return null;
}

/**
 * Metadata for an uploaded object, or null if it isn't there. Post creation
 * uses this to confirm the upload actually happened and to enforce the size
 * cap, which a signed upload URL cannot carry.
 */
async function statObject(path) {
  return storage.statObject(FEED_MEDIA.bucket, path);
}

/**
 * Mints a signed upload URL for one post's media. The client PUTs the raw
 * bytes straight to Supabase Storage with it; this backend never proxies the
 * media data, which is the whole point of doing it this way — a 64MB video
 * must not travel through a 2GB droplet's Node process.
 */
async function createUploadUrl({ userId, mimeType }) {
  return storage.createUploadUrl(FEED_MEDIA.bucket, buildPath(userId, mimeType));
}

/** Mints a short-lived signed URL to view one post's media. */
async function createViewUrl(path, options) {
  return storage.createViewUrl(FEED_MEDIA.bucket, path, {
    expiresInSeconds: FEED_MEDIA.viewUrlSeconds,
    ...options,
  });
}

/**
 * Best-effort removal of a deleted post's object. Called after the row is
 * already soft-deleted, so a storage failure here leaves an orphaned object
 * (a storage cost) rather than a visible post (a safety problem).
 */
async function remove(path) {
  return storage.remove(FEED_MEDIA.bucket, path);
}

/**
 * Whether a post's media is playable video. Small helper so route code reads
 * as product logic rather than string comparison.
 */
const isVideo = (mediaType) => mediaType === POST_MEDIA_TYPE.VIDEO;

module.exports = {
  isConfigured,
  createUploadUrl,
  createViewUrl,
  statObject,
  remove,
  pathBelongsToUser,
  buildPath,
  mediaTypeForPath,
  isVideo,
};
