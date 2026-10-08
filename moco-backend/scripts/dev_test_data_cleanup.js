'use strict';

/**
 * Dev test-data cleanup: finds accounts that test runs created, proves each
 * one is test data from evidence (never from a name alone), and removes
 * them through the SAME admin permanent-delete route the console uses — so
 * ledgers, calls, payouts, purchases and the audit log are kept/anonymised
 * exactly as for any deletion. Then scans Storage for files whose owner is
 * gone.
 *
 *   node scripts/dev_test_data_cleanup.js            # inventory only (default)
 *   node scripts/dev_test_data_cleanup.js --apply    # delete definite test data
 *
 * Needs the backend running (ADMIN_E2E_BASE, default http://localhost:3000)
 * and ADMIN_PHONES in .env.
 *
 * An account is DEFINITELY test data only with one of these proofs:
 *  - smoke fingerprint: smoke's freshTestPhone() builds the number from the
 *    clock (9_000_000_000 + Date.now() % 900_000_000), so the phone's digits
 *    match the account's own created_at to within two minutes;
 *  - an admin audit entry created the account with a test reason ("smoke",
 *    "browser verification", "e2e …");
 *  - an e2e script's account name ("E2E …", "Dialog Shot Author").
 * Seeded accounts (+9198000000xx callers, +9199000000xx listeners), the
 * fixtures the tests run against, and admins are always protected.
 * Everything else is reported as uncertain and left alone.
 */
require('dotenv').config();
const { pool, close: closeDb } = require('../src/config/db');
const { signToken, isAdminUser } = require('../src/middleware/auth');
const { findOrCreateUser } = require('../src/modules/auth/auth.service');
const storage = require('../src/integrations/storage');
const { FEED_MEDIA, LISTENER_PHOTOS, CHAT_MEDIA } = require('../src/utils/constants');

const APPLY = process.argv.includes('--apply');
const BASE = process.env.ADMIN_E2E_BASE || 'http://localhost:3000';
const TEST_AUDIT_REASON = /^(smoke\b|browser verification$|e2e\b)/i;
const E2E_NAME = /^(E2E |Dialog Shot Author$)/;
// Accounts the test suites themselves sign in as / call against.
const FIXTURE_PHONES = new Set(['+919822398913', '+919999999999']);
const isSeeded = (phone) => /^\+91(98|99)000000\d\d$/.test(phone || '');

/** Does the phone carry smoke's clock fingerprint for this creation time? */
function smokeFingerprint(phone, createdAt) {
  const m = /^\+91(9\d{9})$/.exec(phone || '');
  if (!m) return false;
  const expected = 9_000_000_000 + (new Date(createdAt).getTime() % 900_000_000);
  // Some smoke accounts replace the last two digits (…71, …72).
  return Math.abs(Math.floor(Number(m[1]) / 100) - Math.floor(expected / 100)) <= 1200;
}

async function inventory() {
  const { rows: users } = await pool.query(
    `SELECT u.id, u.phone, u.email, u.display_name, u.status, u.created_at,
            (SELECT string_agg(DISTINCT al.reason, ' | ') FROM admin_audit_log al
              WHERE al.action IN ('user.create', 'listener.create') AND al.target_id = u.id::text) AS create_reason
       FROM users u WHERE u.status <> 'deleted' ORDER BY u.id`,
  );
  const definite = [];
  const uncertain = [];
  const protectedRows = [];
  for (const u of users) {
    if (isAdminUser(u) || isSeeded(u.phone) || FIXTURE_PHONES.has(u.phone)) {
      protectedRows.push({ ...u, why: isAdminUser(u) ? 'admin' : isSeeded(u.phone) ? 'seeded' : 'test fixture' });
      continue;
    }
    const evidence = [];
    if (smokeFingerprint(u.phone, u.created_at)) evidence.push('smoke phone fingerprint');
    if (u.create_reason && TEST_AUDIT_REASON.test(u.create_reason)) evidence.push(`created by admin with reason "${u.create_reason}"`);
    if (E2E_NAME.test(u.display_name || '')) evidence.push('e2e script name');
    (evidence.length ? definite : uncertain).push({ ...u, evidence });
  }
  return { definite, uncertain, protectedRows, total: users.length };
}

async function counts(ids) {
  if (ids.length === 0) return {};
  const { rows } = await pool.query(
    `SELECT
       (SELECT count(*)::int FROM posts WHERE author_user_id = ANY($1)) AS posts,
       (SELECT count(*)::int FROM listener_photos WHERE listener_id = ANY($1)) AS creator_photos,
       (SELECT count(*)::int FROM messages WHERE sender_id = ANY($1)) AS messages_sent,
       (SELECT count(*)::int FROM messages WHERE sender_id = ANY($1) AND media_path IS NOT NULL) AS chat_photos_sent,
       (SELECT count(*)::int FROM notifications WHERE user_id = ANY($1)) AS notifications,
       (SELECT count(*)::int FROM listener_relations WHERE user_id = ANY($1) OR listener_id = ANY($1)) AS follows_favorites,
       (SELECT count(*)::int FROM blocks WHERE blocker_id = ANY($1) OR blocked_id = ANY($1)) AS blocks,
       (SELECT count(*)::int FROM listener_profiles WHERE user_id = ANY($1)) AS creator_profiles,
       (SELECT count(*)::int FROM calls WHERE caller_id = ANY($1) OR listener_id = ANY($1)) AS calls_retained,
       (SELECT count(*)::int FROM coin_ledger WHERE user_id = ANY($1)) AS coin_ledger_retained,
       (SELECT count(*)::int FROM listener_earnings WHERE listener_id = ANY($1)) AS earnings_ledger_retained,
       (SELECT count(*)::int FROM purchases WHERE user_id = ANY($1)) AS purchases_retained,
       (SELECT count(*)::int FROM payouts WHERE listener_id = ANY($1)) AS payouts_retained,
       (SELECT count(*)::int FROM reports WHERE reporter_id = ANY($1) OR reported_id = ANY($1)) AS reports_retained`,
    [ids],
  );
  return rows[0];
}

/** Storage objects whose owner folder (`<userId>/`) belongs to no live
 * account and that no row references. Everything else is left alone. */
async function storageScan() {
  const referenced = new Set();
  const refs = await pool.query(
    `SELECT 'feed-media/' || media_path AS p FROM posts
     UNION ALL SELECT 'listener-media/' || storage_path FROM listener_photos
     UNION ALL SELECT 'chat-media/' || media_path FROM messages WHERE media_path IS NOT NULL`,
  );
  for (const r of refs.rows) referenced.add(r.p);
  const bg = await pool.query("SELECT value FROM app_settings WHERE key = 'login_background'");
  for (const k of ['imagePath', 'videoPath']) if (bg.rows[0]?.value?.[k]) referenced.add(`feed-media/${bg.rows[0].value[k]}`);
  const live = new Set((await pool.query("SELECT id::text AS id FROM users WHERE status <> 'deleted'")).rows.map((r) => r.id));

  const out = { orphaned: [], keptReferenced: 0, uncertain: [] };
  for (const bucket of [FEED_MEDIA.bucket, LISTENER_PHOTOS.bucket, CHAT_MEDIA.bucket]) {
    for (const folder of await storage.listFolders(bucket)) {
      if (!/^\d+$/.test(folder)) {
        // e.g. feed-media/app/… (login background): admin-managed, never swept here.
        out.uncertain.push(`${bucket}/${folder}/ (not a user folder — left untouched)`);
        continue;
      }
      const files = await storage.listPrefix(bucket, folder);
      for (const path of files) {
        const key = `${bucket}/${path}`;
        if (referenced.has(key)) out.keptReferenced += 1;
        else if (!live.has(folder)) out.orphaned.push({ bucket, path });
        else out.uncertain.push(`${key} (unreferenced, but its owner #${folder} is a live account)`);
      }
    }
  }
  return out;
}

async function main() {
  const inv = await inventory();
  console.log(`\n=== Accounts (not yet deleted): ${inv.total}`);
  console.log(`  protected: ${inv.protectedRows.length} — ${inv.protectedRows.map((u) => `#${u.id} ${u.display_name || '—'} (${u.why})`).join(', ')}`);
  console.log(`  DEFINITELY test: ${inv.definite.length}`);
  const byEvidence = {};
  for (const u of inv.definite) for (const e of u.evidence) byEvidence[e] = (byEvidence[e] || 0) + 1;
  for (const [e, n] of Object.entries(byEvidence)) console.log(`    ${n} × ${e}`);
  const names = {};
  for (const u of inv.definite) names[u.display_name || '(no name)'] = (names[u.display_name || '(no name)'] || 0) + 1;
  console.log(`    by name: ${Object.entries(names).map(([n, c]) => `${n} ×${c}`).join(', ')}`);
  console.log(`  UNCERTAIN (left alone): ${inv.uncertain.length}`);
  for (const u of inv.uncertain) console.log(`    #${u.id} ${u.display_name || '(no name)'} ${u.phone ? `••${u.phone.slice(-4)}` : ''}${u.email ? ' (email account)' : ''} created ${u.created_at.toISOString().slice(0, 10)}`);
  console.log('\n=== What deleting the definite set touches');
  console.log(await counts(inv.definite.map((u) => Number(u.id))));

  const before = await storageScan();
  console.log(`\n=== Storage: ${before.keptReferenced} referenced files kept; ${before.orphaned.length} orphaned (owner gone); ${before.uncertain.length} uncertain`);
  for (const u of before.uncertain) console.log(`    uncertain: ${u}`);

  if (!APPLY) {
    console.log('\nInventory only. Re-run with --apply to delete the DEFINITE set and the orphaned files.');
    return;
  }

  const adminPhone = (process.env.ADMIN_PHONES || '').split(',')[0]?.trim();
  const token = signToken((await findOrCreateUser(adminPhone)).user);
  const result = { deleted: 0, skipped: [], storage: { feed: 0, creatorPhotos: 0, chat: 0, unregistered: 0 } };
  for (const u of inv.definite) {
    const res = await fetch(`${BASE}/api/admin/users/${u.id}`, {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ reason: `dev test-data cleanup: ${u.evidence[0]}`.slice(0, 500), confirm: String(u.id) }),
    });
    const body = await res.json().catch(() => ({}));
    if (res.ok) {
      result.deleted += 1;
      for (const k of Object.keys(result.storage)) result.storage[k] += body.storageObjectsRemoved?.[k] || 0;
    } else {
      result.skipped.push(`#${u.id}: ${res.status} ${body.error?.message || ''}`);
    }
  }
  console.log(`\n=== Deleted ${result.deleted} accounts; storage removed by the delete flow:`, result.storage);
  if (result.skipped.length) console.log('  skipped:', result.skipped);

  const after = await storageScan();
  let swept = 0;
  const byBucket = {};
  for (const o of after.orphaned) (byBucket[o.bucket] ||= []).push(o.path);
  for (const [bucket, paths] of Object.entries(byBucket)) swept += (await storage.removeStrict(bucket, paths)).removed.length;
  console.log(`=== Orphaned files removed afterwards: ${swept}; uncertain left untouched: ${after.uncertain.length}`);
}

main()
  .then(async () => { await closeDb(); process.exit(0); })
  .catch(async (err) => { console.error('CLEANUP FAILED', err); await closeDb().catch(() => {}); process.exit(1); });
