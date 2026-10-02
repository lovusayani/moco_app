'use strict';

/**
 * Ensures every private Supabase Storage bucket the backend relies on exists.
 * Idempotent: an existing bucket is left untouched (only reported), a missing
 * one is created PRIVATE. Run once per Supabase project:
 *
 *   node scripts/ensure_storage_buckets.js
 *
 * chat-media and feed-media pre-date this script and were created by hand;
 * they are listed so a fresh project gets all three from one command.
 */

require('dotenv').config();
const { createClient } = require('@supabase/supabase-js');
const { CHAT_MEDIA, FEED_MEDIA, LISTENER_PHOTOS } = require('../src/utils/constants');

const BUCKETS = [
  { name: CHAT_MEDIA.bucket },
  { name: FEED_MEDIA.bucket },
  {
    name: LISTENER_PHOTOS.bucket,
    // Defence in depth only — the API already validates type and size before
    // any row references an object.
    fileSizeLimit: LISTENER_PHOTOS.maxBytes,
    allowedMimeTypes: [...LISTENER_PHOTOS.allowedMimeTypes],
  },
];

async function main() {
  const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } = process.env;
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    console.error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set');
    process.exit(1);
  }
  const url = new URL(SUPABASE_URL);
  const client = createClient(`${url.protocol}//${url.host}`, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const { data: existing, error } = await client.storage.listBuckets();
  if (error) throw error;
  const names = new Set(existing.map((bucket) => bucket.name));

  for (const bucket of BUCKETS) {
    if (names.has(bucket.name)) {
      const found = existing.find((b) => b.name === bucket.name);
      console.log(`exists   ${bucket.name} (public: ${found.public})`);
      if (found.public) console.warn(`  WARNING: ${bucket.name} is PUBLIC — it should be private`);
      continue;
    }
    const { error: createError } = await client.storage.createBucket(bucket.name, {
      public: false,
      ...(bucket.fileSizeLimit ? { fileSizeLimit: bucket.fileSizeLimit } : {}),
      ...(bucket.allowedMimeTypes ? { allowedMimeTypes: bucket.allowedMimeTypes } : {}),
    });
    if (createError) throw createError;
    console.log(`created  ${bucket.name} (private)`);
  }
}

main().catch((err) => {
  console.error('FAILED:', err.message);
  process.exit(1);
});
