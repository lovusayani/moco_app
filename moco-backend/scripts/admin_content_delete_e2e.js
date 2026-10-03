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
 * It creates ONE throwaway author with ONE post, signs in through the admin
 * login form exactly as a person does, opens Content / Posts, clicks the
 * row's Delete, types a short real-world reason, confirms, and asserts:
 *   - the browser sent DELETE /api/admin/posts/:id with { reason } and auth
 *   - the response was 200
 *   - the row disappears from the refreshed list
 *   - the post row is gone from the database and its file from Storage
 *   - the audit log holds the deletion with that reason
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
// A short reason a person actually types. This exact case used to be refused
// (the delete routes demanded 5+ characters while the dialog only said
// "required"), so it stays in the test.
const REASON = 'spam';
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
  'base64',
);
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

async function main() {
  const adminPhone = (process.env.ADMIN_PHONES || '').split(',')[0]?.trim();
  if (!adminPhone) throw new Error('ADMIN_PHONES is not set');
  const adminToken = signToken((await findOrCreateUser(adminPhone)).user);

  // Throwaway author + post, through the public API like the app does it.
  const author = (await findOrCreateUser(`+9133${String(Date.now()).slice(-8)}`)).user;
  const authorToken = signToken(author);
  await api('PATCH', '/users/me', authorToken, { displayName: 'E2E Delete Author' });
  const auth = await api('POST', '/feed/media/upload-url', authorToken, { mimeType: 'image/png' });
  await fetch(auth.body.uploadUrl, {
    method: 'PUT',
    headers: { Authorization: `Bearer ${auth.body.token}`, 'Content-Type': 'image/png' },
    body: PNG,
  });
  const created = await api('POST', '/feed', authorToken, { mediaPath: auth.body.path, caption: 'e2e delete me' });
  const postId = created.body.post?.id;
  const mediaPath = auth.body.path;
  check('(setup) throwaway post exists with its stored file',
    created.status === 201 && (await storage.statObject(FEED_MEDIA.bucket, mediaPath)) !== null, created.body);

  const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, defaultViewport: { width: 1366, height: 768 } });
  try {
    const page = await browser.newPage();
    let request = null;
    let response = null;
    page.on('request', (r) => {
      if (r.method() === 'DELETE' && r.url().endsWith(`/api/admin/posts/${postId}`)) {
        request = { url: r.url(), body: r.postData(), hasAuth: Boolean(r.headers().authorization) };
      }
    });
    page.on('response', async (r) => {
      if (r.request().method() === 'DELETE' && r.url().endsWith(`/api/admin/posts/${postId}`)) {
        response = { status: r.status(), body: await r.text().catch(() => '') };
      }
    });
    const settle = async () => {
      await page.waitForNetworkIdle({ idleTime: 400, timeout: 15000 }).catch(() => {});
      await sleep(250);
    };

    // Sign in through the real login form.
    await page.goto(`${BASE}/admin/`, { waitUntil: 'networkidle0' });
    await page.evaluate(() => localStorage.clear());
    await page.reload({ waitUntil: 'networkidle0' });
    await page.type('#phone', adminPhone);
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

    // Content → find the post → row Delete → reason → confirm.
    await page.evaluate(() => { location.hash = '#/content'; });
    await settle();
    await page.type('.dt-toolbar input[type=search]', 'e2e delete me');
    await sleep(500);
    await settle();
    const button = await page.$(`[data-post-del="${postId}"]`);
    check('Content / Posts shows a Delete button for the post', Boolean(button));
    await button.click();
    await page.waitForSelector('.modal');
    await page.type('#f_reason', REASON);
    await page.click('.modal button[type=submit]');
    const toast = await page.waitForSelector('.toast', { timeout: 15000 }).then((el) => el.evaluate((t) => t.textContent)).catch(() => '');
    await settle();

    check('the UI sent DELETE /api/admin/posts/:id with the reason and auth',
      request && JSON.parse(request.body || '{}').reason === REASON && request.hasAuth, request);
    check('DELETE returned 200', response?.status === 200, response);
    check(`the UI reported success ("${toast}")`, new RegExp(`Deleted post #${postId}`).test(toast));
    check('the dialog closed', !(await page.$('.modal')));
    check('the post disappeared from the refreshed list', !(await page.$(`[data-post-del="${postId}"]`)));
  } finally {
    await browser.close();
  }

  const row = await pool.query('SELECT 1 FROM posts WHERE id = $1', [postId]);
  check('the post row is gone from the database', row.rowCount === 0);
  check('the post file is gone from Storage', (await storage.statObject(FEED_MEDIA.bucket, mediaPath)) === null);
  const audit = await pool.query(
    "SELECT reason FROM admin_audit_log WHERE action = 'content.delete_permanent' AND target_id = $1",
    [String(postId)],
  );
  check('the audit log records the deletion with its reason', audit.rows[0]?.reason === REASON, audit.rows);

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
