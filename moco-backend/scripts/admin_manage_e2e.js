'use strict';

/**
 * End-to-end: admin management through the REAL console and backend —
 * account edit, creator edit, creator photo upload + delete, post caption
 * edit + delete, and deletion of a never-billed call record. Run against a
 * running server:
 *
 *   npm run e2e:admin-manage
 *
 * Needs: the backend on :3000 (or ADMIN_E2E_BASE), ADMIN_PHONES in .env,
 * Supabase Storage configured, and Chrome (CHROME_PATH, default: the
 * standard Windows install path).
 *
 * Everything it touches is created here and named "E2E Manage …": one caller,
 * one creator, one post, one failed call. All of it is deleted at the end
 * through the same admin delete flow. Nothing seeded or real is touched;
 * the only existing data it reads is one billed call, to check it is
 * refused (read-only GET).
 */
require('dotenv').config();
const puppeteer = require('puppeteer-core');
const { pool, close: closeDb } = require('../src/config/db');
const { signToken } = require('../src/middleware/auth');
const { findOrCreateUser } = require('../src/modules/auth/auth.service');
const storage = require('../src/integrations/storage');
const { FEED_MEDIA, LISTENER_PHOTOS } = require('../src/utils/constants');

const BASE = process.env.ADMIN_E2E_BASE || 'http://localhost:3000';
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
  'base64',
);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const stamp = String(Date.now()).slice(-7);

let failed = 0;
function check(label, condition, extra) {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failed += 1;
    console.error(`  FAIL ${label}`, extra ?? '');
  }
}

async function api(method, path, token, body) {
  const response = await fetch(`${BASE}/api${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: response.status, body: await response.json().catch(() => ({})) };
}

const lastAudit = async (action, targetId) =>
  (await pool.query(
    'SELECT admin_user_id, reason, metadata FROM admin_audit_log WHERE action = $1 AND target_id = $2 ORDER BY id DESC LIMIT 1',
    [action, String(targetId)],
  )).rows[0];

async function main() {
  const adminPhone = (process.env.ADMIN_PHONES || '').split(',')[0]?.trim();
  if (!adminPhone) throw new Error('ADMIN_PHONES is not set');
  const A = signToken((await findOrCreateUser(adminPhone)).user);

  // --- Throwaway data, created the way the app/console create it.
  const caller = (await findOrCreateUser(`+9144${stamp}01`)).user;
  const callerToken = signToken(caller);
  await api('PATCH', '/users/me', callerToken, { displayName: `E2E Manage Caller ${stamp}` });
  const creatorRes = await api('POST', '/admin/listeners', A, {
    phone: `+9144${stamp}02`, displayName: `E2E Manage Creator ${stamp}`, languages: ['en'], reason: 'e2e manage setup',
  });
  const creatorId = creatorRes.body.id;
  check('(setup) throwaway caller and creator exist', caller.id && creatorRes.status === 201, creatorRes.body);
  const up = await api('POST', '/feed/media/upload-url', callerToken, { mimeType: 'image/png' });
  await fetch(up.body.uploadUrl, { method: 'PUT', headers: { Authorization: `Bearer ${up.body.token}`, 'Content-Type': 'image/png' }, body: PNG });
  const post = (await api('POST', '/feed', callerToken, { mediaPath: up.body.path, caption: `e2e manage post ${stamp}` })).body.post;
  const callRow = await pool.query(
    `INSERT INTO calls (caller_id, listener_id, type, status, agora_channel, rate_per_minute, listener_rate_per_minute, ended_at, end_reason)
     VALUES ($1, $2, 'audio', 'failed', $3, 6, 3, now(), 'e2e_unanswered') RETURNING id`,
    [caller.id, creatorId, `e2e_manage_${stamp}`],
  );
  const callId = callRow.rows[0].id;
  check('(setup) throwaway post and never-billed failed call exist', post?.id && callId);

  // --- Authorization on every new mutation.
  const nonAdmin = callerToken;
  const routes = [
    ['PATCH', `/admin/users/${caller.id}`, { displayName: 'x', reason: 'abc' }],
    ['PATCH', `/admin/listeners/${creatorId}/profile`, { bio: 'x', reason: 'abc' }],
    ['POST', `/admin/listeners/${creatorId}/photos/upload-url`, { mimeType: 'image/png' }],
    ['PATCH', `/admin/posts/${post.id}`, { caption: 'x', reason: 'abc' }],
    ['DELETE', `/admin/calls/${callId}`, { reason: 'abc' }],
  ];
  for (const [m, p, b] of routes) {
    const out = await api(m, p, null, b);
    const non = await api(m, p, nonAdmin, b);
    check(`${m} ${p.replace(/\d+/g, ':id')}: signed out 401, non-admin 403`, out.status === 401 && non.status === 403, [out.status, non.status]);
  }

  // --- Server-side validation and the billing rule.
  const dupPhone = await api('PATCH', `/admin/users/${caller.id}`, A, { phone: adminPhone, reason: 'e2e dup' });
  check('editing a phone to one another account uses is refused (409)', dupPhone.status === 409, dupPhone.body);
  const noIdentity = await api('PATCH', `/admin/users/${caller.id}`, A, { phone: '', reason: 'e2e none' });
  check('removing the only sign-in identity is refused (400)', noIdentity.status === 400, noIdentity.body);
  const adminIdentity = await api('PATCH', `/admin/users/${(await findOrCreateUser(adminPhone)).user.id}`, A, { email: `e2e${stamp}@example.com`, reason: 'e2e admin' });
  check("an admin's own identity cannot be changed (409)", adminIdentity.status === 409, adminIdentity.body);
  const billed = (await pool.query("SELECT id FROM calls WHERE billed_minutes > 0 OR started_at IS NOT NULL LIMIT 1")).rows[0];
  if (billed) {
    const d = await api('GET', `/admin/calls/${billed.id}/deletability`, A);
    check('a connected/billed call is not deletable (billing history)', d.status === 200 && d.body.deletable === false, d.body);
  }

  const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, defaultViewport: { width: 1366, height: 860 } });
  try {
    const page = await browser.newPage();
    const errors = [];
    const native = [];
    page.on('pageerror', (e) => errors.push(e.message));
    page.on('dialog', async (d) => { native.push(d.type()); await d.dismiss(); });
    const settle = async () => { await page.waitForNetworkIdle({ idleTime: 400, timeout: 15000 }).catch(() => {}); await sleep(250); };
    const goTo = async (view, search) => {
      await page.evaluate(() => { location.hash = '#/overview'; });
      await settle();
      await page.evaluate((v) => { location.hash = `#/${v}`; }, view);
      await settle();
      if (search) { await page.type('.dt-toolbar input[type=search]', search); await sleep(500); await settle(); }
    };
    const fill = async (sel, value) => {
      await page.$eval(sel, (el) => { el.value = ''; });
      if (value) await page.type(sel, value);
    };
    const submit = async () => { await page.click('.modal button[type=submit]'); await settle(); };
    const modalError = () => page.$eval('.modal .error-msg', (e) => (e.hidden ? '' : e.textContent)).catch(() => '');
    const modalOpen = async () => Boolean(await page.$('.modal'));

    await page.goto(`${BASE}/admin/`, { waitUntil: 'networkidle0' });
    await page.evaluate((t, p) => { localStorage.setItem('moco_admin_token', t); localStorage.setItem('moco_admin_phone', p); }, A, adminPhone);
    await page.reload({ waitUntil: 'networkidle0' });
    await page.waitForSelector('#app:not([hidden])', { timeout: 15000 });

    // 1. Users → row Edit → dialog validation → save.
    await goTo('users', `E2E Manage Caller ${stamp}`);
    await page.click(`[data-row-edit="${caller.id}"]`);
    await page.waitForSelector('.modal');
    await fill('#f_displayName', `E2E Manage Renamed ${stamp}`);
    await fill('#f_email', 'not-an-email');
    await fill('#f_reason', 'e2e edit');
    await submit();
    check(`user edit: invalid email is refused inside the dialog ("${await modalError()}")`, (await modalOpen()) && /email/i.test(await modalError()));
    await fill('#f_email', `e2e.manage.${stamp}@example.com`);
    await fill('#f_reason', 'x');
    await submit();
    check('user edit: a too-short reason is refused inside the dialog', (await modalOpen()) && /reason/i.test(await modalError()));
    await fill('#f_reason', 'e2e edit details');
    await submit();
    check('user edit: dialog closes after saving', !(await modalOpen()));
    const u = (await pool.query('SELECT display_name, email FROM users WHERE id = $1', [caller.id])).rows[0];
    check('user edit: name and email saved', u.display_name === `E2E Manage Renamed ${stamp}` && u.email === `e2e.manage.${stamp}@example.com`, u);
    const ua = await lastAudit('user.edit', caller.id);
    check('user edit: audited with admin, reason and masked identity',
      ua?.admin_user_id && ua.reason === 'e2e edit details' && ua.metadata.changes.displayName && /•••@example\.com/.test(ua.metadata.changes.email.to), ua);

    // 2. Creators → drawer → Edit profile.
    await goTo('listeners', `E2E Manage Creator ${stamp}`);
    await page.click(`[data-row-edit="${creatorId}"]`);
    await page.waitForSelector('.modal');
    await fill('#f_bio', `E2E bio ${stamp}`);
    await page.click('[data-multi="languages"][value="hi"]');
    await page.click('#f_acceptsVideo');
    await fill('#f_reason', 'e2e creator edit');
    await submit();
    check('creator edit: dialog closes after saving', !(await modalOpen()), await modalError());
    const lp = (await pool.query('SELECT bio, languages, accepts_audio, accepts_video FROM listener_profiles WHERE user_id = $1', [creatorId])).rows[0];
    check('creator edit: bio, languages and capability saved', lp.bio === `E2E bio ${stamp}` && lp.languages.includes('hi') && lp.accepts_video === false, lp);
    check('creator edit: audited', (await lastAudit('listener.edit', creatorId))?.reason === 'e2e creator edit');

    // 3. Creator drawer → Add photo (real file upload) → Delete photo.
    await page.click('table tbody tr td');
    await page.waitForSelector('[data-act="add-photo"]', { timeout: 15000 });
    await page.click('[data-act="add-photo"]');
    await page.waitForSelector('.modal #f_file');
    const fs = require('fs');
    const os = require('os');
    const path = require('path');
    const tmp = path.join(os.tmpdir(), `e2e_manage_${stamp}.png`);
    fs.writeFileSync(tmp, PNG);
    await (await page.$('#f_file')).uploadFile(tmp);
    await fill('#f_reason', 'e2e add photo');
    await submit();
    await sleep(800);
    await settle();
    check('photo add: dialog closes after uploading', !(await modalOpen()), await modalError());
    const photo = (await pool.query('SELECT id, storage_path FROM listener_photos WHERE listener_id = $1', [creatorId])).rows[0];
    check('photo add: row registered and file in Storage', photo && (await storage.statObject(LISTENER_PHOTOS.bucket, photo.storage_path)) !== null, photo);
    check('photo add: audited', (await lastAudit('listener_photo.add', creatorId))?.reason === 'e2e add photo');
    if (photo) {
      await page.waitForSelector(`[data-photo-del="${photo.id}"]`, { timeout: 15000 });
      await page.click(`[data-photo-del="${photo.id}"]`);
      await page.waitForSelector('.modal');
      await fill('#f_reason', 'e2e delete photo');
      await submit();
      check('photo delete: dialog closes', !(await modalOpen()), await modalError());
      const gone = (await pool.query('SELECT 1 FROM listener_photos WHERE id = $1', [photo.id])).rowCount === 0;
      check('photo delete: row and Storage file gone', gone && (await storage.statObject(LISTENER_PHOTOS.bucket, photo.storage_path)) === null);
    }
    fs.unlinkSync(tmp);

    // 4. Content → row Edit caption → row Delete.
    await page.evaluate(() => document.querySelector('[data-close]')?.click());
    await goTo('content', String(post.id));
    await page.click(`[data-post-edit="${post.id}"]`);
    await page.waitForSelector('.modal');
    await fill('#f_caption', `edited by e2e ${stamp}`);
    await fill('#f_reason', 'e2e caption');
    await submit();
    check('post edit: caption saved', (await pool.query('SELECT caption FROM posts WHERE id = $1', [post.id])).rows[0]?.caption === `edited by e2e ${stamp}`);
    check('post edit: audited', (await lastAudit('content.edit', post.id))?.reason === 'e2e caption');
    await page.click(`[data-post-del="${post.id}"]`);
    await page.waitForSelector('.modal');
    await fill('#f_reason', 'e2e delete post');
    await submit();
    check('post delete: row and file gone',
      (await pool.query('SELECT 1 FROM posts WHERE id = $1', [post.id])).rowCount === 0 &&
        (await storage.statObject(FEED_MEDIA.bucket, up.body.path)) === null);

    // 5. Calls → row Delete on the never-billed call.
    await goTo('calls', `E2E Manage Renamed ${stamp}`);
    const btn = await page.$(`[data-call-del="${callId}"]`);
    check('calls: the never-billed call shows a Delete action', Boolean(btn));
    if (btn) {
      await btn.click();
      await page.waitForSelector('.modal');
      await fill('#f_reason', 'e2e delete unbilled call');
      await submit();
      check('call delete: row gone', (await pool.query('SELECT 1 FROM calls WHERE id = $1', [callId])).rowCount === 0);
      check('call delete: audited', (await lastAudit('call.delete_unbilled', callId))?.reason === 'e2e delete unbilled call');
    }

    check('no browser alert/prompt/confirm was used', native.length === 0, native);
    check('no uncaught JavaScript errors', errors.length === 0, errors);
  } finally {
    await browser.close();
  }

  // --- Cleanup through the same permanent-delete flow.
  await pool.query('DELETE FROM calls WHERE id = $1 AND started_at IS NULL AND billed_minutes = 0', [callId]);
  for (const id of [caller.id, creatorId]) {
    const r = await api('DELETE', `/admin/users/${id}`, A, { reason: 'e2e manage cleanup', confirm: String(id) });
    check(`(cleanup) throwaway account #${id} deleted`, r.status === 200, r.body);
  }
}

main()
  .then(async () => {
    console.log(failed ? `\n${failed} check(s) failed` : '\nall checks passed');
    await closeDb();
    process.exit(failed ? 1 : 0);
  })
  .catch(async (err) => {
    console.error('E2E CRASHED', err);
    await closeDb().catch(() => {});
    process.exit(1);
  });
