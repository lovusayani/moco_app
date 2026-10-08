'use strict';

/**
 * Regression: "dark overlay appears but no dialog" on Content / Posts Delete.
 * Real admin page + real backend on :3000 (or ADMIN_E2E_BASE). Run:
 *
 *   npm run e2e:admin-dialog-visibility
 *
 * Needs ADMIN_PHONES in .env, Supabase Storage configured, and Chrome
 * (CHROME_PATH, default: the standard Windows install path). Uses ONE
 * throwaway post, never submits a deletion, and removes the throwaway
 * author at the end. Nothing seeded or real is touched.
 *
 * Fails if only the overlay appears: the dialog must exist, have a real
 * size, sit inside the viewport and be the topmost element at its title,
 * reason field, Cancel and Confirm. It also checks that a dialog hidden by
 * a stylesheet (as a content blocker can do) never leaves a bare overlay,
 * and that Escape / a backdrop click cancel.
 */
require('dotenv').config();
const puppeteer = require('puppeteer-core');
const { close: closeDb } = require('../src/config/db');
const { signToken } = require('../src/middleware/auth');
const { findOrCreateUser } = require('../src/modules/auth/auth.service');

const BASE = process.env.ADMIN_E2E_BASE || 'http://localhost:3000';
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
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

/** What a person can actually see/use of the dialog, measured in the page. */
function inspectDialog() {
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const overlay = document.querySelector('.modal-backdrop');
  const modal = document.querySelector('.modal');
  const topmostIn = (el) => {
    if (!el || !modal) return false;
    const b = el.getBoundingClientRect();
    if (b.width < 1 || b.height < 1) return false;
    const x = Math.min(Math.max(b.left + b.width / 2, 0), vw - 1);
    const y = Math.min(Math.max(b.top + b.height / 2, 0), vh - 1);
    const hit = document.elementsFromPoint(x, y).find((e) => !e.closest('.toast'));
    return Boolean(hit && (hit === el || el.contains(hit)));
  };
  const o = overlay?.getBoundingClientRect();
  const r = modal?.getBoundingClientRect();
  return {
    overlayVisible: Boolean(o && o.width >= vw - 1 && o.height >= vh - 1 && getComputedStyle(overlay).display !== 'none'),
    dialogExists: Boolean(modal),
    box: r ? [r.left, r.top, r.width, r.height].map(Math.round) : null,
    hasSize: Boolean(r && r.width > 0 && r.height > 0),
    insideViewport: Boolean(r && r.top >= 0 && r.left >= 0 && r.bottom <= vh + 0.5 && r.right <= vw + 0.5),
    title: modal?.querySelector('h3')?.textContent ?? null,
    titleVisible: topmostIn(modal?.querySelector('h3')),
    reasonVisible: (() => {
      const f = modal?.querySelector('#f_reason');
      if (!f) return false;
      f.scrollIntoView({ block: 'nearest' });
      return topmostIn(f);
    })(),
    cancelVisible: topmostIn(modal?.querySelector('[data-cancel]')),
    confirmVisible: topmostIn(modal?.querySelector('button[type=submit]')),
  };
}

async function main() {
  const adminPhone = (process.env.ADMIN_PHONES || '').split(',')[0]?.trim();
  if (!adminPhone) throw new Error('ADMIN_PHONES is not set');
  const adminToken = signToken((await findOrCreateUser(adminPhone)).user);

  const author = (await findOrCreateUser(`+9122${String(Date.now()).slice(-8)}`)).user;
  const authorToken = signToken(author);
  await api('PATCH', '/users/me', authorToken, { displayName: 'E2E Dialog Author' });
  const auth = await api('POST', '/feed/media/upload-url', authorToken, { mimeType: 'image/png' });
  await fetch(auth.body.uploadUrl, {
    method: 'PUT',
    headers: { Authorization: `Bearer ${auth.body.token}`, 'Content-Type': 'image/png' },
    body: PNG,
  });
  const created = await api('POST', '/feed', authorToken, { mediaPath: auth.body.path, caption: 'e2e dialog check' });
  const postId = created.body.post?.id;
  check('(setup) throwaway post created', created.status === 201 && postId, created.body);

  const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, defaultViewport: { width: 1366, height: 768 } });
  try {
    const page = await browser.newPage();
    const uncaught = [];
    page.on('pageerror', (e) => uncaught.push(e.message));
    const nativeDialogs = [];
    page.on('dialog', async (d) => { nativeDialogs.push(`${d.type()}: ${d.message().split('\n')[0]}`); await d.dismiss(); });
    const assetStatus = {};
    page.on('response', (r) => {
      const m = r.url().match(/\/admin\/(admin\.(?:js|css))(\?v=[0-9a-f]+)?$/);
      if (m) assetStatus[m[1]] = { status: r.status(), versioned: Boolean(m[2]) };
    });
    const settle = async () => {
      await page.waitForNetworkIdle({ idleTime: 400, timeout: 15000 }).catch(() => {});
      await sleep(250);
    };
    const openContentDelete = async () => {
      await page.evaluate(() => { location.hash = '#/overview'; });
      await settle();
      await page.evaluate(() => { location.hash = '#/content'; });
      await settle();
      await page.type('.dt-toolbar input[type=search]', 'e2e dialog check');
      await sleep(500);
      await settle();
      // Scroll the page/table first, like a person reaching a lower row.
      await page.evaluate(() => {
        document.getElementById('main').scrollTop = 1e6;
        document.querySelectorAll('.dt-scroll').forEach((d) => { d.scrollTop = 1e6; });
      });
      await page.click(`[data-post-del="${postId}"]`);
      await sleep(400); // two animation frames + the visibility self-check
    };

    await page.goto(`${BASE}/admin/`, { waitUntil: 'networkidle0' });
    await page.evaluate((t, p) => { localStorage.setItem('moco_admin_token', t); localStorage.setItem('moco_admin_phone', p); }, adminToken, adminPhone);
    await page.reload({ waitUntil: 'networkidle0' });
    check('admin page loads versioned admin.js and admin.css (200)',
      ['admin.js', 'admin.css'].every((f) => assetStatus[f]?.versioned && [200, 304].includes(assetStatus[f]?.status)), assetStatus);

    // 1. The real path: Content row Delete opens a complete, usable dialog.
    await openContentDelete();
    const d = await page.evaluate(inspectDialog);
    check('overlay is visible', d.overlayVisible, d);
    check('dialog exists inside the overlay', d.dialogExists, d);
    check(`dialog has a real size (${d.box})`, d.hasSize, d.box);
    check('dialog is inside the viewport', d.insideViewport, d.box);
    check(`title is visible ("${d.title}")`, d.titleVisible && /delete post/i.test(d.title || ''), d);
    check('reason field is visible/reachable', d.reasonVisible, d);
    check('Cancel is visible', d.cancelVisible, d);
    check('Confirm is visible', d.confirmVisible, d);
    check('no fallback prompt was needed', nativeDialogs.length === 0, nativeDialogs);

    // 2. Ways out: Escape and a backdrop click cancel (no stuck overlay).
    await page.keyboard.press('Escape');
    await sleep(200);
    check('Escape closes the dialog and the overlay', !(await page.$('.modal-backdrop')));
    await openContentDelete();
    await page.mouse.click(5, 5);
    await sleep(200);
    check('a click on the backdrop closes the dialog and the overlay', !(await page.$('.modal-backdrop')));

    // 3. A stylesheet hiding the dialog (as a content blocker can) must not
    //    leave the admin behind a bare overlay.
    await page.addStyleTag({ content: '.modal { display: none !important; }' });
    await openContentDelete();
    await sleep(300);
    const bareOverlay = await page.$('.modal-backdrop');
    const toast = await page.$eval('.toast', (t) => t.textContent).catch(() => '');
    check('hidden dialog: the overlay is removed, never left on its own', !bareOverlay);
    check('hidden dialog: the admin is told and gets the browser\'s own prompt instead',
      /could not be displayed/.test(toast) && nativeDialogs.some((x) => x.startsWith('prompt')), { toast, nativeDialogs });

    check('no uncaught JavaScript errors', uncaught.length === 0, uncaught);
  } finally {
    await browser.close();
  }

  const still = await api('GET', `/admin/posts?q=${postId}`, adminToken);
  check('(nothing was deleted by this test)', (still.body.items || []).some((p) => p.id === postId), still.body.items);
  const cleanup = await api('DELETE', `/admin/users/${author.id}`, adminToken, { reason: 'e2e cleanup', confirm: String(author.id) });
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
