'use strict';

/**
 * Admin → Settings → Live, in a real browser against a real backend.
 *
 *   ADMIN_E2E_BASE=http://localhost:3093 node scripts/admin_live_settings_e2e.js
 *
 * Run it against a LOCAL stack only: a backend with STRIPCASH_* pointing at a
 * provider stub (or a real key) and at least two synced models, with this
 * script's environment pointing at the same local database. It changes the
 * 'live' app setting and restores the previous value at the end.
 *
 * Checks: the Live tab, provider status, real-data preview, layout presets,
 * card field toggles, featured / hidden models, sorting, enable/disable,
 * save + reload persistence, the in-app reset dialog, that no native
 * alert/confirm/prompt is ever used, and that featuring a model never shows
 * it to a viewer it is geobanned for.
 */
require('dotenv').config();
const puppeteer = require('puppeteer-core');
const { query, close: closeDb } = require('../src/config/db');
const { close: closeRedis } = require('../src/config/redis');
const { signToken } = require('../src/middleware/auth');
const { findOrCreateUser } = require('../src/modules/auth/auth.service');

const BASE = process.env.ADMIN_E2E_BASE || 'http://localhost:3093';
const CHROME = process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const ADMIN_PHONE = (process.env.ADMIN_PHONES || '').split(',')[0].trim();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let failed = 0;
function check(label, condition, extra) {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failed += 1;
    console.error(`  FAIL ${label}`, extra ?? '');
  }
}

async function main() {
  if (!ADMIN_PHONE) throw new Error('ADMIN_PHONES must name the admin phone used for this run');
  const before = (await query(`SELECT value FROM app_settings WHERE key = 'live'`)).rows[0]?.value ?? null;
  await query(`DELETE FROM app_settings WHERE key = 'live'`);

  const { user: admin } = await findOrCreateUser(ADMIN_PHONE);
  const token = signToken(admin);

  const browser = await puppeteer.launch({ executablePath: CHROME, headless: 'new', args: ['--window-size=1500,1000'] });
  const page = await browser.newPage();
  await page.setViewport({ width: 1500, height: 1000 });
  // Viewer location for the preview's geoban check.
  await page.setExtraHTTPHeaders({ 'cf-ipcountry': 'DE' });
  await page.evaluateOnNewDocument((t) => {
    localStorage.setItem('moco_admin_token', t);
    window.__native = [];
    for (const fn of ['alert', 'confirm', 'prompt']) {
      window[fn] = (...args) => {
        window.__native.push([fn, String(args[0])]);
        return fn === 'confirm' ? false : null;
      };
    }
  }, token);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));

  const previewNames = () => page.$$eval('[data-frame] .lc', (cards) => cards.map((c) => c.dataset.model));
  // The preview re-renders (debounced) after every change; wait for a new
  // render, then for it to settle.
  let seen = 0;
  const renders = () => page.$eval('[data-frame]', (f) => Number(f.dataset.renders || 0));
  const waitPreview = async () => {
    await page.waitForFunction((n) => Number(document.querySelector('[data-frame]')?.dataset.renders || 0) > n, { timeout: 15000 }, seen);
    for (;;) {
      const r = await renders();
      await sleep(700);
      if ((await renders()) === r) break;
    }
    seen = await renders();
  };
  // Scrolls the control to the middle first, so a sticky bar never takes the click.
  const clickEl = (sel) => page.$eval(sel, (el) => { el.scrollIntoView({ block: 'center' }); el.click(); });

  console.log('== open Settings → Live');
  await page.goto(`${BASE}/admin/#/settings/live`, { waitUntil: 'networkidle0' });
  await page.waitForSelector('[data-frame] .lc, .ls-empty', { timeout: 20000 });
  await waitPreview();
  check('Settings has Login background and Live tabs', (await page.$$eval('.ls-tab', (t) => t.map((x) => x.textContent))).join('|') === 'Login background|Live');
  check('Live tab is active', await page.$eval('.ls-tab.active', (t) => t.textContent === 'Live'));
  check('provider shows as connected', await page.$eval('.ls-provider', (p) => p.textContent.includes('connected')));
  const initial = await previewNames();
  check('preview renders real synced models', initial.length >= 2, initial);
  check('defaults: grid preset, nothing unsaved', await page.$eval('[data-frame]', (f) => f.className.includes('lg-grid')) &&
    (await page.$eval('[data-dirty]', (d) => d.textContent)) === 'All changes saved');

  console.log('== layout presets');
  await clickEl('input[name="ls-preset"][value="compact"]');
  await waitPreview();
  check('Compact preset applies to the preview', await page.$eval('[data-frame]', (f) => f.className.includes('lg-compact')));
  check('Compact preset sets mobile columns to 1', await page.$eval('[data-k="layout.columns.mobile"]', (s) => s.value === '1'));
  await clickEl('[data-device="desktop"]');
  check('desktop preview uses the desktop column count', await page.$eval('[data-frame]', (f) => f.style.getPropertyValue('--cols') === '3'));
  check('unsaved changes are flagged', (await page.$eval('[data-dirty]', (d) => d.textContent)) === 'Unsaved changes');

  console.log('== card field toggles');
  const hasEye = () => page.$eval('[data-frame]', (f) => f.textContent.includes('👁'));
  check('viewer count shown by default', await hasEye());
  await clickEl('[data-k="card.viewers"]');
  await waitPreview();
  check('viewer count hidden after toggling it off', !(await hasEye()));
  await clickEl('[data-k="card.tags"]');
  await waitPreview();
  check('tags appear after toggling them on', (await page.$$('[data-frame] .lc-tags span')).length > 0);

  console.log('== featured + sorting');
  const target = initial[initial.length - 1];
  await page.type('[data-search]', target);
  await page.waitForFunction((n) => [...document.querySelectorAll('[data-results] [data-add="featured"]')].some((b) => b.dataset.name === n), { timeout: 10000 }, target);
  await page.evaluate((n) => [...document.querySelectorAll('[data-results] [data-add="featured"]')].find((b) => b.dataset.name === n).click(), target);
  await page.$eval('[data-k="sort"]', (el) => { el.value = 'featured'; el.dispatchEvent(new Event('change')); });
  await waitPreview();
  const featuredOrder = await previewNames();
  check('featured model is first with "Featured first"', featuredOrder[0] === target, featuredOrder);
  check('featured card is marked', await page.$eval(`[data-frame] .lc[data-model="${target}"]`, (c) => c.classList.contains('lc-featured')));

  console.log('== hidden models');
  const hideMe = initial[0];
  await page.$eval('[data-search]', (i) => { i.value = ''; });
  await page.type('[data-search]', hideMe);
  await page.waitForFunction((n) => [...document.querySelectorAll('[data-results] [data-add="hidden"]')].some((b) => b.dataset.name === n), { timeout: 10000 }, hideMe);
  await page.evaluate((n) => [...document.querySelectorAll('[data-results] [data-add="hidden"]')].find((b) => b.dataset.name === n).click(), hideMe);
  await waitPreview();
  check('"All eligible" ignores the hidden list', (await previewNames()).includes(hideMe));
  await clickEl('input[name="ls-mode"][value="all_except_blocked"]');
  await waitPreview();
  check('"All except hidden" removes the hidden model', !(await previewNames()).includes(hideMe), await previewNames());

  console.log('== save + reload');
  await clickEl('[data-save]');
  await page.waitForFunction(() => document.querySelector('.toast')?.textContent.includes('Live settings saved'), { timeout: 10000 });
  check('saved: nothing unsaved', (await page.$eval('[data-dirty]', (d) => d.textContent)) === 'All changes saved');
  await page.reload({ waitUntil: 'networkidle0' });
  seen = 0;
  await page.waitForSelector('[data-frame] .lc, .ls-empty', { timeout: 20000 });
  await waitPreview();
  check('reload keeps the Compact preset', await page.$eval('input[name="ls-preset"][value="compact"]', (r) => r.checked));
  check('reload keeps the featured model', await page.$eval('[data-tags="featured"]', (t, n) => t.textContent.includes(n), target));
  check('reload keeps the hidden model and mode', await page.$eval('input[name="ls-mode"][value="all_except_blocked"]', (r) => r.checked) &&
    !(await previewNames()).includes(hideMe));
  check('reload keeps the sort', await page.$eval('[data-k="sort"]', (s) => s.value === 'featured'));
  check('reload keeps card toggles', !(await page.$eval('[data-k="card.viewers"]', (c) => c.checked)));
  const stored = (await query(`SELECT value FROM app_settings WHERE key = 'live'`)).rows[0]?.value;
  check('stored in app_settings', stored?.layout?.preset === 'compact' && stored.selection.featured.includes(target));

  console.log('== geobans cannot be overridden');
  const banned = (await query(
    `SELECT username FROM live_models WHERE 'ru' = ANY(blocked_countries) AND status = 'public' LIMIT 1`,
  )).rows[0]?.username;
  if (banned) {
    await page.setExtraHTTPHeaders({ 'cf-ipcountry': 'RU' });
    await clickEl('input[name="ls-mode"][value="selected"]');
    await page.$eval('[data-search]', (i) => { i.value = ''; });
    await page.type('[data-search]', banned);
    await page.waitForFunction((n) => [...document.querySelectorAll('[data-results] [data-add="selected"]')].some((b) => b.dataset.name === n), { timeout: 10000 }, banned);
    await page.evaluate((n) => [...document.querySelectorAll('[data-results] [data-add="selected"]')].find((b) => b.dataset.name === n).click(), banned);
    await waitPreview();
    check(`a model geobanned in RU stays hidden for an RU viewer even when selected (${banned})`, !(await previewNames()).includes(banned));
    await page.setExtraHTTPHeaders({ 'cf-ipcountry': 'DE' });
    await clickEl('[data-revert]');
    await waitPreview();
  } else {
    console.log('  (skipped: no synced model with a country geoban)');
  }

  console.log('== enable / disable');
  await clickEl('[data-k="enabled"]');
  await waitPreview();
  check('disabled: preview says Live shows nothing', await page.$eval('[data-frame]', (f) => f.textContent.includes('disabled')));
  await clickEl('[data-revert]');
  await waitPreview();
  check('discard restores the saved (enabled) state', await page.$eval('[data-k="enabled"]', (c) => c.checked));

  console.log('== in-app dialog, no native prompts');
  await clickEl('[data-defaults]');
  await page.waitForSelector('.modal', { timeout: 5000 });
  check('reset uses the in-app dialog', await page.$eval('.modal h3', (h) => h.textContent.includes('Reset Live settings')));
  await clickEl('.modal [data-cancel]');
  await sleep(200);
  check('cancelling the dialog changes nothing', (await page.$eval('[data-dirty]', (d) => d.textContent)) === 'All changes saved');
  check('no native alert/confirm/prompt was used', (await page.evaluate(() => window.__native.length)) === 0, await page.evaluate(() => window.__native));
  check('no page errors', errors.length === 0, errors);

  await page.screenshot({ path: process.env.ADMIN_E2E_SHOT || 'admin_live_settings.png', fullPage: false });
  await browser.close();

  if (before) {
    await query(`UPDATE app_settings SET value = $1 WHERE key = 'live'`, [JSON.stringify(before)]);
  } else {
    await query(`DELETE FROM app_settings WHERE key = 'live'`);
  }
}

main()
  .catch((err) => {
    failed += 1;
    console.error('E2E CRASHED', err);
  })
  .finally(async () => {
    await closeDb().catch(() => {});
    await closeRedis().catch(() => {});
    console.log(failed ? `\n${failed} check(s) FAILED` : '\nall checks passed');
    process.exit(failed ? 1 : 0);
  });
