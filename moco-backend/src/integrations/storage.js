'use strict';

const { createClient } = require('@supabase/supabase-js');
const env = require('../config/env');

/**
 * One shared Supabase Storage client for every bucket this backend uses
 * (chat-media, feed-media, and any future bucket) — introduced in Phase 3
 * for chat photos, reused here rather than opening a second SDK client per
 * feature. Bucket-specific modules (chat.storage.js, feed.storage.js) wrap
 * this with their own path scheme and validation; nothing outside this file
 * touches the Supabase client directly, and the service-role key lives only
 * here — Flutter never receives it, never talks to Supabase directly.
 */

/**
 * Reduces whatever was put in SUPABASE_URL to the project base URL the SDK
 * actually wants (`https://<ref>.supabase.co`).
 *
 * The dashboard displays the REST endpoint — `.../rest/v1` — far more
 * prominently than the bare project URL, so pasting that one is the obvious
 * mistake to make. The SDK appends its own `/storage/v1/...` to whatever it
 * is given, and the resulting double path fails with "Invalid path specified
 * in request URL", which points nowhere near the actual cause. Normalising is
 * unambiguous here (there is exactly one right answer) and turns a confusing
 * runtime failure into no failure at all.
 */
function normalizeProjectUrl(raw) {
  try {
    const url = new URL(raw);
    return `${url.protocol}//${url.host}`;
  } catch {
    return raw;
  }
}

let client = null;
if (env.supabaseStorage.url && env.supabaseStorage.serviceRoleKey) {
  client = createClient(
    normalizeProjectUrl(env.supabaseStorage.url),
    env.supabaseStorage.serviceRoleKey,
    { auth: { persistSession: false } },
  );
}

const isConfigured = () => client !== null;

/** Mints a signed upload URL for `bucket`/`path`. The caller PUTs bytes
 * straight to Supabase Storage with it; this backend never proxies them. */
async function createUploadUrl(bucket, path) {
  if (!isConfigured()) throw new Error('storage_not_configured');
  const { data, error } = await client.storage.from(bucket).createSignedUploadUrl(path);
  if (error) throw error;
  return { path, uploadUrl: data.signedUrl, token: data.token };
}

/** Mints a short-lived signed URL to view `bucket`/`path`, or null if
 * storage isn't configured or the object doesn't resolve. */
async function createViewUrl(bucket, path, { expiresInSeconds = 3600 } = {}) {
  if (!isConfigured() || !path) return null;
  const { data, error } = await client.storage
    .from(bucket)
    .createSignedUrl(path, expiresInSeconds);
  if (error) return null;
  return data.signedUrl;
}

/**
 * Metadata for one stored object, or null if storage isn't configured or the
 * object does not exist. This is how the backend verifies that a client which
 * claims to have uploaded something actually did, and how it enforces a size
 * cap it cannot put on a signed upload URL itself — the URL is opaque to size,
 * so the check has to happen after the fact, before the object is referenced
 * by a row.
 */
async function statObject(bucket, path) {
  if (!isConfigured() || !path) return null;

  const slash = path.lastIndexOf('/');
  const dir = slash < 0 ? '' : path.slice(0, slash);
  const name = slash < 0 ? path : path.slice(slash + 1);

  const { data, error } = await client.storage
    .from(bucket)
    .list(dir, { search: name, limit: 100 });
  if (error || !Array.isArray(data)) return null;

  // `search` is a prefix/substring match, not an exact one — find the exact
  // name rather than trusting the first result.
  const found = data.find((object) => object.name === name);
  if (!found) return null;

  return {
    path,
    sizeBytes: found.metadata?.size ?? null,
    mimeType: found.metadata?.mimetype ?? null,
  };
}

/** Permanently removes `bucket`/`path`. Best-effort — a failure here must
 * never block the database-side delete that calls it. */
async function remove(bucket, path) {
  if (!isConfigured() || !path) return;
  try {
    await client.storage.from(bucket).remove([path]);
  } catch {
    // The row is still deleted/hidden either way; an orphaned object is a
    // storage cost, not a correctness or safety problem.
  }
}

module.exports = { isConfigured, createUploadUrl, createViewUrl, statObject, remove };
