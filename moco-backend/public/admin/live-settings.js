'use strict';

/**
 * Admin → Settings → Live.
 *
 * Loaded after admin.js and uses its helpers (api, esc, toast, dialog, head,
 * fmtDate, ago, VIEWS). It turns the Settings view into two tabs —
 * "Login background" (unchanged) and "Live" — routed as #/settings and
 * #/settings/live.
 *
 * The Live tab edits one settings document (PUT /api/admin/live/settings),
 * with a live preview that renders real synced models from
 * POST /api/admin/live/preview using the current, unsaved settings. The
 * preview runs the same listing code as the app for the admin's own
 * location, so geobans apply there too; no setting here can change them.
 */
(() => {
  const settingsView = VIEWS.find((v) => v.id === 'settings');
  if (!settingsView) return;

  const TABS = [
    ['general', 'Login background'],
    ['live', 'Live'],
  ];

  settingsView.render = (el) => {
    const tab = location.hash.split('/')[2] === 'live' ? 'live' : 'general';
    el.innerHTML =
      head('Settings', 'App settings managed from the console. Every change is recorded in the audit log.') +
      `<div class="ls-tabs" role="tablist">${TABS.map(
        ([id, label]) =>
          `<button class="ls-tab${id === tab ? ' active' : ''}" role="tab" aria-selected="${id === tab}" data-tab="${id}">${esc(label)}</button>`,
      ).join('')}</div><div data-tab-body></div>`;
    el.querySelectorAll('[data-tab]').forEach((b) =>
      b.addEventListener('click', () => {
        location.hash = b.dataset.tab === 'live' ? '#/settings/live' : '#/settings';
      }),
    );
    const body = el.querySelector('[data-tab-body]');
    if (tab === 'live') {
      renderLiveSettings(body);
    } else {
      body.innerHTML = '<div id="lb"></div>';
      renderLoginBackground(body.querySelector('#lb'));
    }
  };

  /* ------------------------------------------------------------ labels */

  const L = {
    status: { public: 'Public shows only', any: 'All online (public, group and private shows)' },
    layout: { grid: 'Grid', large: 'Large cards', compact: 'Compact', mixed: 'Mixed' },
    aspect: { portrait: 'Portrait 3:4', square: 'Square 1:1', landscape: 'Landscape 4:3', wide: 'Wide 16:9' },
    density: { comfortable: 'Comfortable', cozy: 'Cozy', compact: 'Compact' },
    radius: { none: 'None', small: 'Small', medium: 'Medium', large: 'Large' },
    selectionMode: {
      all: 'All eligible models',
      selected: 'Selected models only',
      all_except_blocked: 'All except hidden models',
    },
    sort: {
      default: 'Stripcash order (provider rating)',
      viewers: 'Most viewers',
      favorites: 'Most favorited',
      featured: 'Featured first',
      hd: 'HD first',
    },
    clickBehavior: {
      internal_player: 'Open the internal Moco Live player',
      provider: 'Open the provider destination (Stripchat)',
    },
    cardFields: {
      snapshot: 'Live snapshot',
      avatar: 'Avatar',
      liveBadge: 'LIVE badge',
      username: 'Username',
      viewers: 'Viewer count',
      country: 'Country',
      languages: 'Languages',
      favorites: 'Favorite count',
      hdBadge: 'HD badge',
      tags: 'Tags',
      goal: 'Goal / progress',
    },
  };

  // A layout preset also picks sensible columns; each can still be changed.
  const PRESET_COLUMNS = {
    grid: { mobile: 2, tablet: 3, desktop: 4 },
    large: { mobile: 1, tablet: 2, desktop: 3 },
    compact: { mobile: 1, tablet: 2, desktop: 3 },
    mixed: { mobile: 2, tablet: 3, desktop: 4 },
  };
  const DEVICE_WIDTH = { mobile: 360, tablet: 600, desktop: 900 };

  const clone = (o) => JSON.parse(JSON.stringify(o));
  const fmtNum = (n) => Number(n || 0).toLocaleString('en-IN');

  /* ------------------------------------------------------------ the tab */

  async function renderLiveSettings(host) {
    host.innerHTML = '<div class="panel"><h3>Live</h3><div class="sub">Loading…</div></div>';
    let data;
    try {
      data = await api('/admin/live/settings');
    } catch (err) {
      host.innerHTML = `<div class="panel"><h3>Live</h3><div class="error-msg">${esc(err.message)}</div></div>`;
      return;
    }
    const { options: O, defaults: DEFAULTS, maxList } = data;
    let saved = stripMeta(data.settings);
    let draft = clone(saved);
    let device = 'mobile';
    let previewTimer = null;
    let previewSeq = 0;

    function stripMeta(s) {
      const { updatedAt, ...rest } = s; // eslint-disable-line no-unused-vars
      return rest;
    }
    const dirty = () => JSON.stringify(draft) !== JSON.stringify(saved);

    const p = data.provider;
    const providerLine = p.configured
      ? `${p.lastSyncOk === false ? badge('sync failing', 'red') : badge('connected', 'green')}
         <span class="sub">Last sync ${p.lastSyncAt ? esc(ago(p.lastSyncAt)) : 'never'}${p.lastSyncError ? ` · ${esc(p.lastSyncError)}` : ''}
         · ${fmtNum(p.online)} online (${fmtNum(p.public)} public) · ${fmtNum(p.stored)} stored</span>`
      : `${badge('not configured', 'amber')} <span class="sub">STRIPCASH_API_KEY / STRIPCASH_USER_ID are not set on the server, so Live shows nothing.</span>`;

    const opt = (values, labels, current) =>
      values.map((v) => `<option value="${esc(v)}" ${String(current) === String(v) ? 'selected' : ''}>${esc(labels?.[v] ?? v)}</option>`).join('');
    const chips = (name, values, labels, current) =>
      `<div class="ls-chips" role="radiogroup">${values
        .map(
          (v) => `<label class="ls-chip"><input type="radio" name="${name}" value="${esc(v)}" ${current === v ? 'checked' : ''}> ${esc(labels[v] ?? v)}</label>`,
        )
        .join('')}</div>`;

    host.innerHTML = `
      <div class="ls-wrap">
        <div class="ls-form">
          <div class="panel ls-provider"><h3>Provider status</h3><div>${providerLine}</div></div>

          <div class="panel"><h3>Master settings</h3>
            <label class="ls-switch"><input type="checkbox" data-k="enabled"> <span>External Live enabled</span></label>
            <div class="ls-row">
              <div class="field"><label>Provider</label><select data-k="provider">${opt(O.provider, { stripcash: 'Stripcash' }, draft.provider)}</select></div>
              <div class="field"><label>Models per page</label><select data-k="pageSize" data-num>${opt([6, 12, 18, 24, 30, 36, 48, 60], null, draft.pageSize)}</select></div>
            </div>
            <div class="field"><label>Status</label><select data-k="status">${opt(O.status, L.status, draft.status)}</select>
              <div class="help">Private and group shows need payment on the provider; "Public only" is the default.</div></div>
            <div class="ls-row3">
              <div class="field"><label>Preferred language</label><input data-k="preferredLanguage" placeholder="e.g. en" maxlength="3"></div>
              <div class="field"><label>Preferred country</label><input data-k="preferredCountry" placeholder="e.g. in" maxlength="2"></div>
              <div class="field"><label>Preferred tag</label><input data-k="preferredTag" placeholder="e.g. girls/indian" maxlength="64"></div>
            </div>
            <div class="help">Preferences move matching models up the list; they never hide anyone.</div>
            <label class="ls-switch"><input type="checkbox" data-k="requireAgeConfirmation"> <span>Ask for 18+ confirmation before Live opens</span></label>
          </div>

          <div class="panel"><h3>Layout</h3>
            <div class="field"><label>Preset</label>${chips('ls-preset', O.layout, L.layout, draft.layout.preset)}</div>
            <div class="ls-row3">
              <div class="field"><label>Mobile columns</label><select data-k="layout.columns.mobile" data-num>${opt([1, 2, 3], null, draft.layout.columns.mobile)}</select></div>
              <div class="field"><label>Tablet columns</label><select data-k="layout.columns.tablet" data-num>${opt([2, 3, 4], null, draft.layout.columns.tablet)}</select></div>
              <div class="field"><label>Desktop columns</label><select data-k="layout.columns.desktop" data-num>${opt([2, 3, 4, 5, 6], null, draft.layout.columns.desktop)}</select></div>
            </div>
            <div class="ls-row3">
              <div class="field"><label>Card aspect ratio</label><select data-k="layout.aspect">${opt(O.aspect, L.aspect, draft.layout.aspect)}</select></div>
              <div class="field"><label>Card density</label><select data-k="layout.density">${opt(O.density, L.density, draft.layout.density)}</select></div>
              <div class="field"><label>Corner radius</label><select data-k="layout.radius">${opt(O.radius, L.radius, draft.layout.radius)}</select></div>
            </div>
          </div>

          <div class="panel"><h3>Card content</h3>
            <div class="ls-checks">${O.cardFields
              .map((f) => `<label class="ls-check"><input type="checkbox" data-k="card.${f}"> ${esc(L.cardFields[f])}</label>`)
              .join('')}</div>
          </div>

          <div class="panel"><h3>Model selection</h3>
            <div class="field">${chips('ls-mode', O.selectionMode, L.selectionMode, draft.selection.mode)}
              <div class="help" data-mode-help></div></div>
            <div class="ls-lists">
              ${['featured', 'hidden', 'selected']
                .map(
                  (list) => `<div class="ls-list" data-list="${list}">
                    <div class="ls-list-head"><strong>${list === 'featured' ? 'Featured' : list === 'hidden' ? 'Hidden / blocked' : 'Selected'}</strong>
                      <span class="sub" data-count="${list}"></span>
                      ${list !== 'featured' ? '' : '<span class="sub">· shown first when sorting "Featured first", in this order</span>'}</div>
                    <div class="ls-tags" data-tags="${list}"></div></div>`,
                )
                .join('')}
            </div>
            <div class="field ls-search"><label>Find synced models</label>
              <input data-search placeholder="Search by username" maxlength="64">
              <div class="ls-results" data-results></div></div>
          </div>

          <div class="panel"><h3>Sorting</h3>
            <div class="field"><label>Default order</label><select data-k="sort">${opt(O.sort, L.sort, draft.sort)}</select>
              <div class="help">Custom weighted sorting comes later.</div></div>
          </div>

          <div class="panel"><h3>When a user taps a model</h3>
            ${chips('ls-click', O.clickBehavior, L.clickBehavior, draft.clickBehavior)}
          </div>

          <div class="ls-savebar">
            <span class="sub" data-dirty></span>
            <button class="btn-ghost btn-sm" data-revert>Discard changes</button>
            <button class="btn-ghost btn-sm" data-defaults>Reset to defaults</button>
            <button class="btn-primary inline" data-save>Save</button>
          </div>
          <div class="help">${data.settings.updatedAt ? `Last saved ${esc(fmtDate(data.settings.updatedAt))}.` : 'Never saved — using the defaults.'}</div>
        </div>

        <div class="ls-preview-col">
          <div class="panel ls-preview-panel"><h3>Preview <span class="sub" data-preview-note></span></h3>
            <div class="ls-devices" role="tablist">${['mobile', 'tablet', 'desktop']
              .map((d) => `<button class="ls-device${d === device ? ' active' : ''}" data-device="${d}">${d[0].toUpperCase() + d.slice(1)}</button>`)
              .join('')}</div>
            <div class="ls-frame-wrap"><div class="ls-frame" data-frame></div></div>
            <div class="help" data-viewer></div>
          </div>
        </div>
      </div>`;

    const $ = (sel) => host.querySelector(sel);
    const $$ = (sel) => [...host.querySelectorAll(sel)];

    /* ---------------- draft <-> controls */

    const getPath = (obj, path) => path.split('.').reduce((o, k) => o?.[k], obj);
    const setPath = (obj, path, value) => {
      const keys = path.split('.');
      const last = keys.pop();
      keys.reduce((o, k) => o[k], obj)[last] = value;
    };

    function fillControls() {
      for (const input of $$('[data-k]')) {
        const value = getPath(draft, input.dataset.k);
        if (input.type === 'checkbox') input.checked = Boolean(value);
        else input.value = value ?? '';
      }
      const setRadio = (name, value) => $$(`input[name="${name}"]`).forEach((r) => { r.checked = r.value === value; });
      setRadio('ls-preset', draft.layout.preset);
      setRadio('ls-mode', draft.selection.mode);
      setRadio('ls-click', draft.clickBehavior);
      renderLists();
      updateDirty();
    }

    for (const input of $$('[data-k]')) {
      const handler = () => {
        let value;
        if (input.type === 'checkbox') value = input.checked;
        else if ('num' in input.dataset) value = Number(input.value);
        else value = input.value.trim() || null;
        setPath(draft, input.dataset.k, value);
        changed();
      };
      input.addEventListener(input.tagName === 'INPUT' && input.type !== 'checkbox' ? 'input' : 'change', handler);
    }
    $$('input[name="ls-preset"]').forEach((r) =>
      r.addEventListener('change', () => {
        draft.layout.preset = r.value;
        draft.layout.columns = clone(PRESET_COLUMNS[r.value]);
        fillControls();
        changed();
      }),
    );
    $$('input[name="ls-mode"]').forEach((r) => r.addEventListener('change', () => { draft.selection.mode = r.value; renderLists(); changed(); }));
    $$('input[name="ls-click"]').forEach((r) => r.addEventListener('change', () => { draft.clickBehavior = r.value; changed(); }));

    function updateDirty() {
      const d = dirty();
      $('[data-dirty]').textContent = d ? 'Unsaved changes' : 'All changes saved';
      $('[data-dirty]').classList.toggle('ls-unsaved', d);
      $('[data-save]').disabled = !d;
      $('[data-revert]').disabled = !d;
    }

    function changed() {
      updateDirty();
      clearTimeout(previewTimer);
      previewTimer = setTimeout(loadPreview, 350);
    }

    /* ---------------- featured / hidden / selected */

    const MODE_HELP = {
      all: 'Every eligible model is shown. The hidden list is kept but not applied in this mode.',
      selected: 'Only models on the Selected list are shown (minus any on the Hidden list).',
      all_except_blocked: 'Every eligible model except those on the Hidden list.',
    };

    function renderLists() {
      $('[data-mode-help]').textContent = MODE_HELP[draft.selection.mode];
      for (const list of ['featured', 'hidden', 'selected']) {
        const names = draft.selection[list];
        $(`[data-count="${list}"]`).textContent = `${names.length}/${maxList}`;
        const inactive =
          (list === 'hidden' && draft.selection.mode === 'all') || (list === 'selected' && draft.selection.mode !== 'selected');
        $(`[data-list="${list}"]`).classList.toggle('ls-inactive', inactive);
        $(`[data-tags="${list}"]`).innerHTML = names.length
          ? names
              .map(
                (n, i) => `<span class="ls-tag" data-name="${esc(n)}">${list === 'featured' ? `<em>${i + 1}</em>` : ''}${esc(n)}
                  ${list === 'featured' && i > 0 ? `<button class="ls-x" title="Move up" data-up="${esc(n)}">↑</button>` : ''}
                  <button class="ls-x" title="Remove" data-remove="${esc(n)}">×</button></span>`,
              )
              .join('')
          : '<span class="sub">None</span>';
        $$(`[data-tags="${list}"] [data-remove]`).forEach((b) =>
          b.addEventListener('click', () => {
            draft.selection[list] = draft.selection[list].filter((x) => x !== b.dataset.remove);
            renderLists();
            changed();
          }),
        );
        $$(`[data-tags="${list}"] [data-up]`).forEach((b) =>
          b.addEventListener('click', () => {
            const arr = draft.selection.featured;
            const i = arr.indexOf(b.dataset.up);
            [arr[i - 1], arr[i]] = [arr[i], arr[i - 1]];
            renderLists();
            changed();
          }),
        );
      }
    }

    function addTo(list, name) {
      const arr = draft.selection[list];
      if (arr.includes(name)) return;
      if (arr.length >= maxList) {
        toast(`The ${list} list is full (${maxList}).`, false);
        return;
      }
      arr.push(name);
      // A model cannot be both featured and hidden.
      if (list === 'hidden') draft.selection.featured = draft.selection.featured.filter((x) => x !== name);
      if (list === 'featured') draft.selection.hidden = draft.selection.hidden.filter((x) => x !== name);
      renderLists();
      changed();
    }

    let searchTimer = null;
    async function search() {
      const q = $('[data-search]').value.trim();
      const box = $('[data-results]');
      box.innerHTML = '<div class="sub">Searching…</div>';
      try {
        const { models } = await api(`/admin/live/models${qs({ q, limit: 20 })}`);
        box.innerHTML = models.length
          ? models
              .map(
                (m) => `<div class="ls-result">
                  ${m.imageUrl ? `<img src="${esc(m.imageUrl)}" alt="" loading="lazy" referrerpolicy="no-referrer">` : '<span class="ls-noimg"></span>'}
                  <div class="ls-result-main"><strong>${esc(m.username)}</strong>
                    <span class="sub">${m.online ? `${badge(m.status === 'public' ? 'live' : m.status, m.status === 'public' ? 'green' : 'grey')} ${fmtNum(m.viewers)} viewers` : `offline · seen ${esc(ago(m.lastSeenAt))}`}${m.country ? ` · ${esc(m.country.toUpperCase())}` : ''}</span></div>
                  <div class="ls-result-actions">
                    <button class="btn-ghost btn-sm" data-add="featured" data-name="${esc(m.username)}">Feature</button>
                    <button class="btn-ghost btn-sm" data-add="hidden" data-name="${esc(m.username)}">Hide</button>
                    <button class="btn-ghost btn-sm" data-add="selected" data-name="${esc(m.username)}">Select</button>
                  </div></div>`,
              )
              .join('')
          : `<div class="sub">${q ? 'No synced model matches.' : 'No synced models yet.'}</div>`;
        box.querySelectorAll('[data-add]').forEach((b) => b.addEventListener('click', () => addTo(b.dataset.add, b.dataset.name)));
      } catch (err) {
        box.innerHTML = `<div class="error-msg">${esc(err.message)}</div>`;
      }
    }
    $('[data-search]').addEventListener('input', () => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(search, 250);
    });

    /* ---------------- preview */

    $$('[data-device]').forEach((b) =>
      b.addEventListener('click', () => {
        device = b.dataset.device;
        $$('[data-device]').forEach((x) => x.classList.toggle('active', x === b));
        renderFrame(lastPreview);
      }),
    );

    let lastPreview = null;
    async function loadPreview() {
      const seq = ++previewSeq;
      $('[data-preview-note]').textContent = '· updating…';
      try {
        const result = await api('/admin/live/preview', { method: 'POST', body: { settings: draft } });
        if (seq !== previewSeq) return;
        lastPreview = result;
        $('[data-preview-note]').textContent = dirty() ? '· unsaved settings' : '· saved settings';
        const v = result.viewer;
        $('[data-viewer]').textContent = `Real synced models, as the app would list them for your location (${
          v.country ? v.country.toUpperCase() + (v.region ? `-${v.region.toUpperCase()}` : '') : 'unknown — geobanned models hidden'
        }). Geobans always apply.`;
        renderFrame(result);
      } catch (err) {
        if (seq !== previewSeq) return;
        $('[data-preview-note]').textContent = '';
        $('[data-frame]').innerHTML = `<div class="error-msg">${esc(err.message)}</div>`;
      }
    }

    function card(m, s, big) {
      const c = s.card;
      const goal = c.goal && m.goal && m.goal.needed > 0;
      const pct = goal ? Math.min(100, Math.round(((m.goal.earned || 0) / m.goal.needed) * 100)) : 0;
      const img = c.snapshot ? m.snapshotUrl || m.thumbnailUrl : m.thumbnailUrl || m.avatarUrl;
      const meta = [
        c.viewers ? `<span>👁 ${fmtNum(m.viewers)}</span>` : '',
        c.favorites ? `<span>♥ ${fmtNum(m.favorites)}</span>` : '',
        c.country && m.country ? `<span>${esc(m.country.toUpperCase())}</span>` : '',
        c.languages && m.languages.length ? `<span>${esc(m.languages.slice(0, 3).join(', '))}</span>` : '',
      ].filter(Boolean).join('');
      return `<div class="lc${big ? ' lc-big' : ''}${m.featured ? ' lc-featured' : ''}" data-model="${esc(m.username)}">
        <div class="lc-media">${img ? `<img src="${esc(img)}" alt="" loading="lazy" referrerpolicy="no-referrer">` : ''}
          ${c.liveBadge ? '<span class="lc-live">LIVE</span>' : ''}
          ${c.hdBadge && m.isHd ? '<span class="lc-hd">HD</span>' : ''}
          ${m.featured ? '<span class="lc-star" title="Featured">★</span>' : ''}</div>
        <div class="lc-body">
          ${c.avatar || c.username ? `<div class="lc-name">${c.avatar && m.avatarUrl ? `<img class="lc-avatar" src="${esc(m.avatarUrl)}" alt="" referrerpolicy="no-referrer">` : ''}${c.username ? `<strong>${esc(m.username)}</strong>` : ''}</div>` : ''}
          ${meta ? `<div class="lc-meta">${meta}</div>` : ''}
          ${c.tags && m.tags.length ? `<div class="lc-tags">${m.tags.slice(0, 3).map((t) => `<span>${esc(t)}</span>`).join('')}</div>` : ''}
          ${goal ? `<div class="lc-goal" title="${esc(m.goal.message || '')}"><div style="width:${pct}%"></div></div>` : ''}
        </div></div>`;
    }

    let renders = 0;
    function renderFrame(result) {
      const frame = $('[data-frame]');
      if (!result) return;
      frame.dataset.renders = String(++renders);
      const s = draft;
      frame.style.width = `${DEVICE_WIDTH[device]}px`;
      frame.className = `ls-frame lg-${s.layout.preset} la-${s.layout.aspect} ld-${s.layout.density} lr-${s.layout.radius}`;
      frame.style.setProperty('--cols', s.layout.columns[device]);
      if (!s.enabled) {
        frame.innerHTML = '<div class="ls-empty">External Live is disabled — the app shows no Live content.</div>';
        return;
      }
      if (!result.models.length) {
        frame.innerHTML = '<div class="ls-empty">No models match these settings right now.</div>';
        return;
      }
      frame.innerHTML = `<div class="lc-grid">${result.models
        .map((m, i) => card(m, s, s.layout.preset === 'mixed' && i % 7 === 0))
        .join('')}</div><div class="ls-click-note">Tap → ${esc(L.clickBehavior[s.clickBehavior])}</div>`;
    }

    /* ---------------- save / revert / defaults */

    $('[data-save]').addEventListener('click', async (e) => {
      const button = e.currentTarget;
      button.disabled = true;
      try {
        const res = await api('/admin/live/settings', { method: 'PUT', body: { settings: draft } });
        saved = stripMeta(res.settings);
        draft = clone(saved);
        fillControls();
        toast('Live settings saved');
        loadPreview();
      } catch (err) {
        toast(err.message, false);
        updateDirty();
      }
    });
    $('[data-revert]').addEventListener('click', () => {
      draft = clone(saved);
      fillControls();
      changed();
      toast('Unsaved changes discarded');
    });
    $('[data-defaults]').addEventListener('click', async () => {
      const ok = await dialog({
        title: 'Reset Live settings to the defaults?',
        message: 'The form is filled with the default settings, including empty featured, hidden and selected lists. Nothing changes until you press Save.',
        confirmLabel: 'Fill with defaults',
        onSubmit: () => true,
      });
      if (!ok) return;
      draft = clone(DEFAULTS);
      fillControls();
      changed();
    });

    fillControls();
    search();
    loadPreview();
  }
})();
