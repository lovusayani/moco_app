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
 * Signed view URLs for many objects in ONE storage request — admin lists show
 * dozens of photos/posts per page, and one HTTP call per image would make
 * every page load an N+1 against Storage. Returns a Map path → url (paths
 * that fail to sign are simply absent).
 */
async function createViewUrls(bucket, paths, { expiresInSeconds = 3600 } = {}) {
  const unique = [...new Set(paths.filter(Boolean))];
  if (!isConfigured() || unique.length === 0) return new Map();
  const { data, error } = await client.storage
    .from(bucket)
    .createSignedUrls(unique, expiresInSeconds);
  if (error || !Array.isArray(data)) return new Map();
  return new Map(data.filter((d) => d.signedUrl && !d.error).map((d) => [d.path, d.signedUrl]));
}

/** Liveness of Storage itself, for the admin system-health page. Reports
 * bucket names and privacy only — never keys or URLs. */
async function health() {
  if (!isConfigured()) return { ok: false, configured: false };
  const started = Date.now();
  const { data, error } = await client.storage.listBuckets();
  if (error) return { ok: false, configured: true, error: error.message };
  return {
    ok: true,
    configured: true,
    latencyMs: Date.now() - started,
    buckets: data.map((b) => ({ name: b.name, private: !b.public })),
  };
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

/**
 * Permanently removes `bucket`/`paths` and THROWS if Storage refuses — the
 * strict counterpart to [remove], for admin permanent deletion, where the
 * caller runs it inside its database transaction so a Storage failure rolls
 * the row deletion back instead of leaving an orphaned object. Removing a
 * path that no longer exists is not an error, so a retry is always safe.
 */
async function removeStrict(bucket, paths) {
  const unique = [...new Set(paths.filter(Boolean))];
  if (unique.length === 0) return { removed: [] };
  if (!isConfigured()) {
    throw Object.assign(new Error('Storage is not configured, so stored media cannot be removed'), {
      code: 'storage_not_configured',
    });
  }
  const removed = [];
  for (let i = 0; i < unique.length; i += 100) {
    const batch = unique.slice(i, i + 100);
    const { data, error } = await client.storage.from(bucket).remove(batch);
    if (error) {
      throw Object.assign(new Error(`Storage refused to remove objects from ${bucket}: ${error.message}`), {
        code: 'storage_remove_failed',
      });
    }
    removed.push(...(data || []).map((object) => object.name));
  }
  return { removed };
}

/**
 * Every object directly under `prefix/` in `bucket` (uploads are stored as
 * `<userId>/<file>`, one level deep). Used to find uploads that were never
 * registered against a row, so deleting an account leaves nothing behind.
 */
async function listPrefix(bucket, prefix) {
  if (!isConfigured() || !prefix) return [];
  const paths = [];
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await client.storage.from(bucket).list(prefix, { limit: 1000, offset });
    if (error) {
      throw Object.assign(new Error(`Storage refused to list ${bucket}/${prefix}: ${error.message}`), {
        code: 'storage_list_failed',
      });
    }
    // Folder placeholders have no id; only real objects are returned.
    paths.push(...data.filter((object) => object.id).map((object) => `${prefix}/${object.name}`));
    if (data.length < 1000) break;
  }
  return paths;
}

module.exports = {
  isConfigured,
  createUploadUrl,
  createViewUrl,
  createViewUrls,
  health,
  statObject,
  remove,
  removeStrict,
  listPrefix,
};
