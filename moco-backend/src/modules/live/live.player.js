'use strict';

const crypto = require('crypto');
const express = require('express');
const env = require('../../config/env');
const stripcash = require('../../integrations/stripcash');

/**
 * GET /api/live/player-frame — the page that hosts the official Stripchat
 * player, embedded by the web app in an iframe.
 *
 * Why a page on the API's origin (api.lovcamx.online) and not one inside the
 * web app: the provider's script then runs on an origin that holds nothing —
 * it cannot read the web app's storage, session token or cookies
 * (lovcamx.online is a different origin) — while still having a real origin,
 * which the player needs to stream (in an opaque-origin sandbox it mounts but
 * never fetches the stream).
 *
 * Everything the page needs comes from the server: the script URL and the
 * affiliate userId are injected here, never taken from the request, so the
 * page cannot be made to load another script. The parent only says which
 * model to show, by postMessage from an allow-listed origin:
 *
 *   parent → frame  { type: 'load', modelName }   destroys any current player,
 *                                                 then mounts one for modelName
 *                   { type: 'destroy' }           app.destroy(), nothing shown
 *   frame → parent  { source: 'moco-live-player', event, payload? }
 *                   event: loading | mounted | destroyed | ready | play |
 *                          pause | volumeChange | muteChange |
 *                          fullscreenChange | error
 *
 * The provider API key and API user id never reach this page.
 */

const EVENTS = ['ready', 'play', 'pause', 'volumeChange', 'muteChange', 'fullscreenChange', 'error'];

/** Origins allowed to embed the player and talk to it. */
function parentOrigins() {
  const list = [...env.cors.origins];
  return { list, localhost: !env.isProduction };
}

function page(nonce, cfg) {
  const data = JSON.stringify(cfg).replace(/</g, '\\u003c');
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>Moco Live player</title>
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#player{position:absolute;inset:0}</style>
</head><body><div id="player"></div>
<script nonce="${nonce}">
(function () {
  var CFG = ${data};
  var EVENTS = ${JSON.stringify(EVENTS)};
  var LOCAL = /^https?:\\/\\/(localhost|127\\.0\\.0\\.1|\\[::1\\])(:\\d+)?$/;
  var NAME = /^[A-Za-z0-9_.-]{1,128}$/;
  var parentOrigin = null, app = null, scriptReady = null, seq = 0;

  function allowed(o) { return CFG.parents.indexOf(o) >= 0 || (CFG.localhost && LOCAL.test(o)); }
  function post(m) {
    if (!parentOrigin) return;
    m.source = 'moco-live-player';
    parent.postMessage(m, parentOrigin);
  }
  // Only plain values cross back to the app.
  function clean(p) {
    var out = {};
    if (p && typeof p === 'object') {
      ['type', 'fatal', 'isFullscreen', 'volume', 'muted'].forEach(function (k) {
        var v = p[k];
        if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') out[k] = v;
      });
    }
    return out;
  }
  // The official script, loaded once per page. It finds itself by this id.
  function loadScript() {
    if (scriptReady) return scriptReady;
    scriptReady = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.id = 'SCPlayerScript';
      s.src = CFG.scriptUrl;
      s.onload = resolve;
      s.onerror = function () { scriptReady = null; reject(new Error('script')); };
      document.head.appendChild(s);
    });
    return scriptReady;
  }
  function destroy() {
    var a = app;
    app = null;
    if (!a) return Promise.resolve();
    return Promise.resolve().then(function () { return a.destroy(); }).catch(function () {});
  }
  function load(name) {
    var mine = ++seq;
    post({ event: 'loading' });
    destroy().then(loadScript).then(function () {
      if (mine !== seq) return;
      var options = { modelName: name, userId: CFG.userId };
      Object.keys(CFG.options).forEach(function (k) { options[k] = CFG.options[k]; });
      return new window.StripchatPlayer(options).mount(document.getElementById('player')).then(function (a) {
        // A newer load (or a destroy) arrived while this one was mounting.
        if (mine !== seq) { a.destroy(); return; }
        app = a;
        EVENTS.forEach(function (n) { a.on(n, function (p) { post({ event: n, payload: clean(p) }); }); });
        post({ event: 'mounted' });
      });
    }).catch(function () {
      if (mine === seq) post({ event: 'error', payload: { type: 'player', fatal: true } });
    });
  }

  window.addEventListener('message', function (e) {
    // Only the embedding page: never a message when opened on its own.
    if (window.parent === window || e.source !== window.parent || !allowed(e.origin)) return;
    if (parentOrigin && e.origin !== parentOrigin) return;
    parentOrigin = e.origin;
    var d = e.data || {};
    if (d.type === 'load' && NAME.test(String(d.modelName || ''))) load(String(d.modelName));
    else if (d.type === 'destroy') { seq++; destroy().then(function () { post({ event: 'destroyed' }); }); }
  });
  window.addEventListener('pagehide', function () { seq++; destroy(); });
})();
</script></body></html>`;
}

const router = express.Router();

router.get('/player-frame', (req, res) => {
  const player = stripcash.playerConfig();
  res.removeHeader('X-Frame-Options');
  res.set('Cache-Control', 'no-store');
  if (!player) {
    res.status(404).type('text/plain').send('The live player is not configured.');
    return;
  }
  const { list, localhost } = parentOrigins();
  const nonce = crypto.randomBytes(16).toString('base64');
  const ancestors = [...list, ...(localhost ? ['http://localhost:*', 'http://127.0.0.1:*'] : [])];
  // The provider's player loads its own chunks, styles, thumbnails and HLS
  // segments from its CDNs, hence https: for those; inline script is limited
  // to this page's own nonce, and only allow-listed origins may frame it.
  res.set(
    'Content-Security-Policy',
    [
      "default-src 'none'",
      `script-src 'nonce-${nonce}' https:`,
      // data:/blob: — the player starts its stream worker from a data: URL.
      'connect-src https: wss: data: blob:',
      'img-src https: data: blob:',
      'media-src https: blob:',
      "style-src 'unsafe-inline' https:",
      'font-src https: data:',
      'worker-src blob: https:',
      'frame-src https:',
      `frame-ancestors ${ancestors.length ? ancestors.join(' ') : "'none'"}`,
      "base-uri 'none'",
      "form-action 'none'",
    ].join('; '),
  );
  res.type('html').send(
    page(nonce, {
      scriptUrl: player.scriptUrl,
      userId: player.userId,
      options: stripcash.PLAYER_OPTIONS,
      parents: list,
      localhost,
    }),
  );
});

module.exports = router;
