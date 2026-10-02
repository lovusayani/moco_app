'use strict';

/**
 * DEVELOPMENT ONLY. Gives every KYC-approved, active listener that has fewer
 * than the minimum photos real placeholder photos, so a dev/QA database keeps
 * a populated Discovery grid under the "approved KYC + 3 photos" rule.
 *
 * These are genuine objects in the private `listener-media` bucket, uploaded
 * through the same signed-upload path the app uses, and registered as normal
 * rows — not fake metadata pointing at nothing. Each is a small solid-colour
 * PNG generated here (no assets, no dependencies).
 *
 *   node scripts/dev_seed_listener_photos.js
 *
 * Refuses to run when NODE_ENV=production.
 */

require('dotenv').config();
const zlib = require('zlib');
const env = require('../src/config/env');
const { pool, close } = require('../src/config/db');
const listenerStorage = require('../src/integrations/listener.storage');
const { LISTENER_PHOTOS, KYC_STATUS } = require('../src/utils/constants');

// ---- minimal PNG encoder (solid colour, 8-bit RGB) -------------------------
const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (const byte of buf) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function solidPng(size, [r, g, b]) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // colour type: RGB
  const row = Buffer.alloc(1 + size * 3);
  for (let x = 0; x < size; x += 1) row.set([r, g, b], 1 + x * 3);
  const raw = Buffer.concat(Array.from({ length: size }, () => row));
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// Moco brand-adjacent tones so placeholders read as intentional in the UI.
const PALETTE = [
  [229, 79, 154],
  [185, 62, 119],
  [242, 154, 110],
  [90, 31, 62],
  [240, 127, 174],
  [246, 162, 60],
];

async function uploadOne(userId, colour) {
  const { path, uploadUrl, token } = await listenerStorage.createUploadUrl({
    userId,
    mimeType: 'image/png',
  });
  const body = solidPng(256, colour);
  const res = await fetch(uploadUrl, {
    method: 'PUT',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'image/png', 'x-upsert': 'false' },
    body,
  });
  if (!res.ok) throw new Error(`upload failed: HTTP ${res.status}`);
  await pool.query(
    `INSERT INTO listener_photos (listener_id, storage_path, mime_type, size_bytes)
     VALUES ($1, $2, 'image/png', $3) ON CONFLICT (storage_path) DO NOTHING`,
    [userId, path, body.length],
  );
}

async function main() {
  if (env.isProduction) {
    console.error('Refusing to run: this script is for development data only.');
    process.exit(1);
  }
  if (!listenerStorage.isConfigured()) {
    console.error('Storage is not configured (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY).');
    process.exit(1);
  }

  const { rows } = await pool.query(
    `SELECT lp.user_id, lp.photo_count FROM listener_profiles lp
       JOIN users u ON u.id = lp.user_id
      WHERE lp.kyc_status = $1 AND u.status = 'active' AND lp.photo_count < $2
      ORDER BY lp.user_id`,
    [KYC_STATUS.APPROVED, LISTENER_PHOTOS.minCount],
  );

  let uploaded = 0;
  for (const listener of rows) {
    const needed = LISTENER_PHOTOS.minCount - listener.photo_count;
    for (let i = 0; i < needed; i += 1) {
      await uploadOne(listener.user_id, PALETTE[(listener.user_id + i) % PALETTE.length]);
      uploaded += 1;
    }
  }
  console.log(`listeners topped up: ${rows.length}, photos uploaded: ${uploaded}`);
  await close();
}

main().catch(async (err) => {
  console.error('FAILED:', err.message);
  await close().catch(() => {});
  process.exit(1);
});
