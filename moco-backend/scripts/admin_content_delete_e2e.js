'use strict';

/**
 * End-to-end: Content / Posts permanent delete through the REAL admin UI and
 * the REAL backend route together. Run manually against a running server:
 *
 *   npm run e2e:admin-content-delete
 *
 * Needs: the backend on :3000 (or ADMIN_E2E_BASE), ADMIN_PHONES in .env, the
 * dev OTP code (non-production), Supabase Storage configured, and Chrome
 * (CHROME_PATH, default: the standard Windows install path).
 *
 * It creates ONE throwaway author with FOUR posts — an active image, an active
 * video, one an admin removed (hidden, file kept) and one the author already
 * deleted (status removed, its file already gone) — signs in through the
 * admin login form as a person does, and for each post:
 * Content / Posts → row Delete → checks the dialog (ID, author, media type,
 * warning) → types a short reason → confirms. It asserts:
 *   - the browser sent DELETE /api/admin/posts/:id with { reason } and auth
 *   - the response was 200
 *   - the dialog closed and the row disappeared from the refreshed list
 *   - the post row is gone from the database and its file from Storage
 *   - the audit log holds the deletion with that reason and the Storage
 *     result (1 file removed for the posts with a file, 0 = already missing for
 *     the author-deleted one — which must not block deletion)
 * The throwaway author is then deleted. Nothing seeded or real is touched.
 */
require('dotenv').config();
const puppeteer = require('puppeteer-core');
const { pool, close: closeDb } = require('../src/config/db');
const { signToken } = require('../src/middleware/auth');
const { findOrCreateUser } = require('../src/modules/auth/auth.service');
const storage = require('../src/integrations/storage');
const { FEED_MEDIA } = require('../src/utils/constants');

const BASE = process.env.ADMIN_E2E_BASE || 'http://localhost:3000';
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
// A short reason a person actually types (it used to be refused).
const REASON = 'spam';
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
  'base64',
);
// A minimal MP4 header — enough for the upload/post path (playback is not tested here).
const MP4 = Buffer.concat([
  Buffer.from([0x00, 0x00, 0x00, 0x18]),
  Buffer.from('ftypmp42'),
  Buffer.from([0x00, 0x00, 0x00, 0x00]),
  Buffer.from('mp42isom'),
]);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: response.status, body: await response.json().catch(() => ({})) };
}

async function createPost(authorToken, caption, { mimeType = 'image/png', bytes = PNG } = {}) {
  const auth = await api('POST', '/feed/media/upload-url', authorToken, { mimeType });
  await fetch(auth.body.uploadUrl, {
    method: 'PUT',
    headers: { Authorization: `Bearer ${auth.body.token}`, 'Content-Type': mimeType },
    body: bytes,
  });
  const created = await api('POST', '/feed', authorToken, { mediaPath: auth.body.path, caption });
  return { id: created.body.post?.id, path: auth.body.path, status: created.status };
}

async function main() {
  const adminPhone = (process.env.ADMIN_PHONES || '').split(',')[0]?.trim();
  if (!adminPhone) throw new Error('ADMIN_PHONES is not set');
  const adminToken = signToken((await findOrCreateUser(adminPhone)).user);

  // Throwaway author + posts, through the public API like the app does it.
  const author = (await findOrCreateUser(`+9133${String(Date.now()).slice(-8)}`)).user;
  const authorToken = signToken(author);
  await api('PATCH', '/users/me', authorToken, { displayName: 'E2E Delete Author' });
  const stamp = String(Date.now()).slice(-6);
  const active = await createPost(authorToken, `e2e active ${stamp}`);
  const removed = await createPost(authorToken, `e2e author-removed ${stamp}`);
  const video = await createPost(authorToken, `e2e video ${stamp}`, { mimeType: 'video/mp4', bytes: MP4 });
  const hidden = await createPost(authorToken, `e2e admin-removed ${stamp}`);
  const hide = await api('POST', `/admin/posts/${hidden.id}`, adminToken, { action: 'remove', reason: 'e2e hide first' });
  const authorDelete = await api('DELETE', `/feed/${removed.id}`, authorToken);
  check('(setup) an active post exists with its stored file',
    active.status === 201 && (await storage.statObject(FEED_MEDIA.bucket, active.path)) !== null, active);
  check('(setup) a second post was deleted by its author (removed, file already gone)',
    authorDelete.status === 200 && (await storage.statObject(FEED_MEDIA.bucket, removed.path)) === null, authorDelete.body);
  check('(setup) an active video post exists with its stored file',
    video.status === 201 && (await storage.statObject(FEED_MEDIA.bucket, video.path)) !== null, video);
  check('(setup) a post was removed (hidden) by an admin, file kept for restore',
    hide.status === 200 && (await storage.statObject(FEED_MEDIA.bucket, hidden.path)) !== null, hide.body);

  const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, defaultViewport: { width: 1366, height: 768 } });
  try {
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', (e) => pageErrors.push(e.message));
    const settle = async () => {
      await page.waitForNetworkIdle({ idleTime: 400, timeout: 15000 }).catch(() => {});
      await sleep(250);
    };

    // Sign in through the real login form (email or phone; phone here).
    await page.goto(`${BASE}/admin/`, { waitUntil: 'networkidle0' });
    await page.evaluate(() => localStorage.clear());
    await page.reload({ waitUntil: 'networkidle0' });
    await page.type('#login-email', adminPhone);
    await page.click('#phone-form button[type=submit]');
    const codeShown = await page.waitForSelector('#code', { visible: true, timeout: 10000 }).then(() => true).catch(() => false);
    if (codeShown) {
      await page.type('#code', process.env.OTP_FIXED_CODE || '123456');
      await page.click('#code-form button[type=submit]');
    } else {
      // OTP requests are rate limited per phone (5/hour). Fall back to a
      // server-minted session for the same admin so the run can proceed.
      console.log('  note: OTP request refused (rate limit?) — using a server-minted admin session instead');
      await page.evaluate((t, p) => { localStorage.setItem('moco_admin_token', t); localStorage.setItem('moco_admin_phone', p); }, adminToken, adminPhone);
      await page.reload({ waitUntil: 'networkidle0' });
    }
    await page.waitForSelector('#app:not([hidden])', { timeout: 15000 });
    check('signed in to the admin console', true);

    for (const [label, post, expectRemoved, mediaLabel] of [
      ['active image post', active, 1, 'Image'],
      ['active video post', video, 1, 'Video'],
      ['admin-removed post', hidden, 1, 'Image'],
      ['author-removed post (file already missing)', removed, 0, 'Image'],
    ]) {
      let request = null;
      let response = null;
      const onRequest = (r) => {
        if (r.method() === 'DELETE' && r.url().endsWith(`/api/admin/posts/${post.id}`)) {
          request = { body: r.postData(), hasAuth: Boolean(r.headers().authorization) };
        }
      };
      const onResponse = async (r) => {
        if (r.request().method() === 'DELETE' && r.url().endsWith(`/api/admin/posts/${post.id}`)) {
          response = { status: r.status(), body: await r.text().catch(() => '') };
        }
      };
      page.on('request', onRequest);
      page.on('response', onResponse);

      await page.evaluate(() => { location.hash = '#/overview'; });
      await settle();
      await page.evaluate(() => { location.hash = '#/content'; });
      await settle();
      await page.type('.dt-toolbar input[type=search]', String(post.id));
      await sleep(500);
      await settle();
      const button = await page.$(`[data-post-del="${post.id}"]`);
      check(`${label}: Content / Posts shows a Delete button`, Boolean(button));
      if (!button) continue;
      await button.click();
      await page.waitForSelector('.modal');
      const dialog = await page.evaluate(() => {
        const m = document.querySelector('.modal');
        const r = m.getBoundingClientRect();
        const submit = m.querySelector('button[type=submit]').getBoundingClientRect();
        return {
          text: m.textContent,
          inView: r.top >= 0 && r.left >= 0 && r.bottom <= innerHeight && r.right <= innerWidth,
          submitVisible: submit.bottom <= innerHeight && submit.width > 0,
        };
      });
      check(`${label}: dialog is visible and usable`, dialog.inView && dialog.submitVisible, dialog);
      check(`${label}: dialog shows ID, author, media type and the permanent warning`,
        dialog.text.includes(`#${post.id}`) && dialog.text.includes('E2E Delete Author') &&
          dialog.text.includes(mediaLabel) && /cannot be undone/.test(dialog.text), dialog.text.slice(0, 200));
      await page.type('#f_reason', REASON);
      await page.click('.modal button[type=submit]');
      // Wait for THIS post's toast (an earlier one may still be showing).
      const toast = await page
        .waitForFunction((id) => { const t = document.querySelector('.toast'); return t && t.textContent.includes(`#${id}`) && t.textContent; }, { timeout: 15000 }, post.id)
        .then((h) => h.jsonValue())
        .catch(() => page.$eval('.toast', (t) => t.textContent).catch(() => ''));
      await settle();

      check(`${label}: the UI sent DELETE /api/admin/posts/:id with the reason and auth`,
        request && JSON.parse(request.body || '{}').reason === REASON && request.hasAuth, request);
      check(`${label}: DELETE returned 200`, response?.status === 200, response);
      check(`${label}: success toast ("${toast}")`, new RegExp(`Deleted post #${post.id}`).test(toast));
      check(`${label}: the dialog closed (no overlay left)`, !(await page.$('.modal-backdrop')));
      check(`${label}: the row disappeared from the refreshed list`, !(await page.$(`[data-post-del="${post.id}"]`)));

      const row = await pool.query('SELECT 1 FROM posts WHERE id = $1', [post.id]);
      check(`${label}: the post row is gone from the database`, row.rowCount === 0);
      check(`${label}: no file remains in Storage`, (await storage.statObject(FEED_MEDIA.bucket, post.path)) === null);
      const audit = await pool.query(
        "SELECT admin_user_id, reason, metadata FROM admin_audit_log WHERE action = 'content.delete_permanent' AND target_id = $1",
        [String(post.id)],
      );
      const entry = audit.rows[0];
      check(`${label}: audit entry with admin, reason and storage result (${expectRemoved} removed)`,
        entry && entry.admin_user_id && entry.reason === REASON &&
          entry.metadata?.storage?.objectsRemoved === expectRemoved &&
          entry.metadata?.storage?.fileAlreadyMissing === (expectRemoved === 0), entry);

      page.off('request', onRequest);
      page.off('response', onResponse);
    }
    check('no uncaught JavaScript errors', pageErrors.length === 0, pageErrors);
  } finally {
    await browser.close();
  }

  const cleanup = await api('DELETE', `/admin/users/${author.id}`, adminToken, {
    reason: 'e2e cleanup',
    confirm: String(author.id),
  });
  check('(cleanup) throwaway author deleted', cleanup.status === 200, cleanup.body);
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
