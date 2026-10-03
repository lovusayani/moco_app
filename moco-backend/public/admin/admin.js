'use strict';

/**
 * Moco admin console — a dependency-free single page served from the API
 * origin (/admin), talking to /api/admin/*.
 *
 * Every authorization decision is made by the server: each /api/admin route
 * re-checks the ADMIN_PHONES allow-list. Nothing hidden or disabled here is
 * access control — it only spares an operator a request that would be
 * refused anyway.
 *
 * Structure: core helpers → reusable components (data table, drawer,
 * dialogs, badges) → auth → router/nav → views.
 */

const API = '/api';
const TOKEN_KEY = 'moco_admin_token';
const PHONE_KEY = 'moco_admin_phone';

let token = localStorage.getItem(TOKEN_KEY);
let pendingPhone = '';

/* =====================================================================
 * Core
 * ===================================================================== */

async function api(path, { method = 'GET', body } = {}) {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = { error: { message: text } };
  }
  if (!response.ok) {
    if (response.status === 401) signOut();
    const details = data?.error?.details;
    const detailText = Array.isArray(details)
      ? details.map((d) => (d.field ? `${d.field}: ${d.message}` : d.message || '')).filter(Boolean).join('; ')
      : '';
    const err = new Error(
      (data?.error?.message || `Request failed (${response.status})`) + (detailText ? ` — ${detailText}` : ''),
    );
    err.code = data?.error?.code;
    err.status = response.status;
    throw err;
  }
  return data;
}

const qs = (params) => {
  const sp = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null && v !== '') sp.set(k, v);
  }
  const s = sp.toString();
  return s ? `?${s}` : '';
};

const esc = (value) =>
  String(value ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );

const num = (v) => Number(v ?? 0).toLocaleString('en-IN');
const coins = (v) => `<span class="money">${num(v)}</span>`;
const rupees = (v) => `<span class="money">₹${num(v)}</span>`;
const signed = (v) => {
  const n = Number(v ?? 0);
  return `<span class="${n >= 0 ? 'pos' : 'neg'}">${n > 0 ? '+' : ''}${num(n)}</span>`;
};

function fmtDate(ts) {
  if (!ts) return '—';
  const d = new Date(ts);
  return d.toLocaleString('en-IN', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function ago(ts) {
  if (!ts) return '—';
  const s = Math.floor((Date.now() - new Date(ts)) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  if (s < 86400 * 30) return `${Math.floor(s / 86400)}d ago`;
  return fmtDate(ts).split(',')[0];
}

const when = (ts) => (ts ? `<span title="${esc(fmtDate(ts))}">${esc(ago(ts))}</span>` : '—');

function duration(start, end) {
  if (!start || !end) return '—';
  const s = Math.max(0, Math.round((new Date(end) - new Date(start)) / 1000));
  const m = Math.floor(s / 60);
  return `${m}:${String(s % 60).padStart(2, '0')}`;
}

let toastTimer;
function toast(message, ok = true, ms = 3600) {
  document.querySelector('.toast')?.remove();
  const el = document.createElement('div');
  el.className = `toast${ok ? '' : ' bad'}`;
  el.textContent = message;
  document.body.appendChild(el);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.remove(), ms);
}

const empty = (mark, message) => `<div class="empty"><div class="empty-mark">${mark}</div>${esc(message)}</div>`;

/* =====================================================================
 * Badges
 * ===================================================================== */

const BADGE_TONE = {
  active: 'green', approved: 'green', paid: 'green', ended: 'green', eligible: 'green',
  verified: 'green', online: 'green', ok: 'green', actioned: 'green',
  pending: 'amber', submitted: 'amber', requested: 'amber', reviewing: 'amber',
  approved_incomplete: 'amber', ringing: 'amber', live: 'amber',
  suspended: 'red', rejected: 'red', deleted: 'red', failed: 'red', removed: 'red', down: 'red',
  open: 'rose', admin: 'rose',
  unsubmitted: 'grey', draft: 'grey', dismissed: 'grey', offline: 'grey', user: 'grey',
  listener: 'blue', both: 'blue', audio: 'blue', video: 'blue', image: 'blue', call: 'blue',
};

const LABEL = {
  approved_incomplete: 'approved · incomplete',
  unsubmitted: 'not submitted',
};

function badge(value, tone) {
  if (value === null || value === undefined || value === '') return '—';
  const t = tone || BADGE_TONE[value] || 'grey';
  return `<span class="badge b-${t}">${esc(LABEL[value] || String(value).replace(/_/g, ' '))}</span>`;
}

const onlineDot = (on) => `<span class="dot ${on ? 'on' : 'off'}" title="${on ? 'online' : 'offline'}"></span>`;

function photosBadge(count, min = 3) {
  return badge(`${count}/${min}`, count >= min ? 'green' : 'red');
}

function blockerBadges(blockers) {
  if (!blockers || blockers.length === 0) return badge('ready', 'green');
  const label = {
    photos: 'needs photos', kyc: 'needs KYC', not_submitted: 'not submitted',
    display_name: 'no name', kyc_documents: 'no documents', account_not_active: 'account inactive',
  };
  return `<span class="blockers">${blockers.map((b) => badge(label[b] || b, 'red')).join('')}</span>`;
}

/* =====================================================================
 * Data table — search, filters, date range, sortable headers, pagination
 * ===================================================================== */

/**
 * cfg: {
 *   endpoint, columns: [{ label, sort?, render(row), num? }],
 *   filters?: [{ key, label, options: [[value,label]] | async () => [[value,label]] }],
 *   initial?: { [filterKey]: value }, sort?, dir?, search? (placeholder|false),
 *   dateRange?: bool, onRow?(row), emptyText?, pageSize?
 * }
 */
function dataTable(host, cfg) {
  const st = {
    page: 1,
    pageSize: cfg.pageSize || 25,
    sort: cfg.sort || '',
    dir: cfg.dir || 'desc',
    q: '',
    from: '',
    to: '',
    f: { ...(cfg.initial || {}) },
  };

  host.innerHTML = `
    <div class="dt">
      <div class="dt-toolbar"></div>
      <div class="dt-scroll"><table><thead></thead><tbody></tbody></table></div>
      <div class="dt-foot"></div>
    </div>`;
  const root = host.querySelector('.dt');
  const toolbar = root.querySelector('.dt-toolbar');
  const thead = root.querySelector('thead');
  const tbody = root.querySelector('tbody');
  const foot = root.querySelector('.dt-foot');

  // Toolbar
  if (cfg.search !== false) {
    const search = document.createElement('input');
    search.type = 'search';
    search.placeholder = cfg.search || 'Search…';
    let t;
    search.addEventListener('input', () => {
      clearTimeout(t);
      t = setTimeout(() => { st.q = search.value.trim(); st.page = 1; load(); }, 300);
    });
    toolbar.appendChild(search);
  }
  for (const f of cfg.filters || []) {
    const sel = document.createElement('select');
    sel.title = f.label;
    const fill = (opts) => {
      sel.innerHTML = `<option value="">${esc(f.label)}: all</option>` +
        opts.map(([v, l]) => `<option value="${esc(v)}">${esc(f.label)}: ${esc(l)}</option>`).join('');
      sel.value = st.f[f.key] ?? '';
    };
    if (typeof f.options === 'function') {
      fill([]);
      f.options().then(fill).catch(() => {});
    } else fill(f.options);
    sel.addEventListener('change', () => { st.f[f.key] = sel.value; st.page = 1; load(); });
    toolbar.appendChild(sel);
  }
  if (cfg.dateRange) {
    for (const key of ['from', 'to']) {
      const d = document.createElement('input');
      d.type = 'date';
      d.title = key === 'from' ? 'From date' : 'To date';
      d.addEventListener('change', () => { st[key] = d.value; st.page = 1; load(); });
      toolbar.appendChild(d);
    }
  }
  const refresh = document.createElement('button');
  refresh.className = 'btn-ghost btn-sm';
  refresh.textContent = 'Refresh';
  refresh.addEventListener('click', () => load());
  toolbar.appendChild(refresh);
  const total = document.createElement('span');
  total.className = 'dt-total';
  toolbar.appendChild(total);

  // Header
  function renderHead() {
    thead.innerHTML = `<tr>${cfg.columns
      .map((c) => {
        const active = c.sort && st.sort === c.sort;
        const arrow = active ? `<span class="arrow">${st.dir === 'asc' ? '▲' : '▼'}</span>` : '';
        return `<th class="${c.sort ? 'sortable' : ''} ${c.num ? 'num' : ''} ${c.pin ? 'col-pin' : ''}" data-sort="${c.sort || ''}">${esc(c.label)}${arrow}</th>`;
      })
      .join('')}</tr>`;
  }
  thead.addEventListener('click', (e) => {
    const th = e.target.closest('th.sortable');
    if (!th) return;
    const key = th.dataset.sort;
    if (st.sort === key) st.dir = st.dir === 'asc' ? 'desc' : 'asc';
    else { st.sort = key; st.dir = 'desc'; }
    st.page = 1;
    load();
  });

  let rows = [];
  tbody.addEventListener('click', (e) => {
    if (e.target.closest('button, a, input, select')) return; // inline controls handle themselves
    const tr = e.target.closest('tr[data-i]');
    if (tr && cfg.onRow) cfg.onRow(rows[Number(tr.dataset.i)]);
  });

  async function load() {
    renderHead();
    root.classList.add('dt-loading');
    try {
      const data = await api(cfg.endpoint + qs({
        page: st.page, pageSize: st.pageSize, sort: st.sort, dir: st.dir,
        q: st.q, from: st.from, to: st.to, ...st.f,
      }));
      rows = data.items || [];
      total.textContent = `${num(data.total)} result${data.total === 1 ? '' : 's'}`;
      tbody.innerHTML = rows.length
        ? rows
            .map((r, i) => `<tr data-i="${i}" class="${cfg.onRow ? 'clickable' : ''}">${cfg.columns
              .map((c) => `<td class="${c.num ? 'num' : ''} ${c.pin ? 'col-pin' : ''}">${c.render(r)}</td>`)
              .join('')}</tr>`)
            .join('')
        : `<tr><td colspan="${cfg.columns.length}">${empty('∅', cfg.emptyText || 'Nothing matches these filters.')}</td></tr>`;
      foot.innerHTML = `
        <span>Page ${data.page} of ${data.totalPages}</span>
        <span class="pager">
          <select title="Rows per page">${[10, 25, 50, 100]
            .map((n) => `<option ${n === st.pageSize ? 'selected' : ''} value="${n}">${n} / page</option>`)
            .join('')}</select>
          <button class="btn-ghost btn-sm" data-p="first" ${data.page <= 1 ? 'disabled' : ''}>«</button>
          <button class="btn-ghost btn-sm" data-p="prev" ${data.page <= 1 ? 'disabled' : ''}>‹ Prev</button>
          <button class="btn-ghost btn-sm" data-p="next" ${data.page >= data.totalPages ? 'disabled' : ''}>Next ›</button>
          <button class="btn-ghost btn-sm" data-p="last" ${data.page >= data.totalPages ? 'disabled' : ''}>»</button>
        </span>`;
      foot.querySelector('select').addEventListener('change', (e) => {
        st.pageSize = Number(e.target.value); st.page = 1; load();
      });
      foot.querySelectorAll('button[data-p]').forEach((b) => b.addEventListener('click', () => {
        const p = b.dataset.p;
        st.page = p === 'first' ? 1 : p === 'last' ? data.totalPages : st.page + (p === 'next' ? 1 : -1);
        load();
      }));
      cfg.afterLoad?.(rows, tbody);
    } catch (err) {
      tbody.innerHTML = `<tr><td colspan="${cfg.columns.length}">${empty('!', err.message)}</td></tr>`;
    } finally {
      root.classList.remove('dt-loading');
    }
  }

  load();
  return { reload: load, state: st };
}

/** A small static (non-paginated) table for drawer panels. */
function miniTable(columns, rows, emptyText = 'None.') {
  if (!rows || rows.length === 0) return `<div class="empty" style="padding:14px">${esc(emptyText)}</div>`;
  return `<div style="overflow:auto"><table><thead><tr>${columns
    .map((c) => `<th class="${c.num ? 'num' : ''}">${esc(c.label)}</th>`)
    .join('')}</tr></thead><tbody>${rows
    .map((r) => `<tr>${columns.map((c) => `<td class="${c.num ? 'num' : ''}">${c.render(r)}</td>`).join('')}</tr>`)
    .join('')}</tbody></table></div>`;
}

const kv = (pairs) =>
  `<dl class="kv">${pairs.filter(Boolean).map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v ?? '—'}</dd>`).join('')}</dl>`;

function timeline(history) {
  if (!history || history.length === 0) return '<div class="empty" style="padding:14px">No admin actions recorded.</div>';
  return `<ul class="timeline">${history
    .map((h) => `<li>${badge(h.action, 'rose')} by <span class="mono">${esc(h.admin_phone)}</span>
      <span class="when">· ${esc(fmtDate(h.created_at))}</span>
      ${h.reason ? `<div style="margin-top:3px">${esc(h.reason)}</div>` : ''}</li>`)
    .join('')}</ul>`;
}

/* =====================================================================
 * Drawer (detail panel)
 * ===================================================================== */

const drawer = {
  current: null,
  async open(title, render) {
    this.current = { title, render };
    const root = document.getElementById('drawer-root');
    root.innerHTML = `
      <div class="drawer-backdrop"></div>
      <aside class="drawer" role="dialog" aria-label="${esc(title)}">
        <div class="drawer-head"><h2>${esc(title)}</h2>
          <button class="btn-ghost btn-sm" data-close>Close ✕</button></div>
        <div class="drawer-body"><div class="empty">Loading…</div></div>
      </aside>`;
    root.querySelector('.drawer-backdrop').addEventListener('click', () => this.close());
    root.querySelector('[data-close]').addEventListener('click', () => this.close());
    const body = root.querySelector('.drawer-body');
    try {
      await render(body);
    } catch (err) {
      body.innerHTML = empty('!', err.message);
    }
  },
  refresh() {
    if (this.current) this.open(this.current.title, this.current.render);
  },
  close() {
    this.current = null;
    document.getElementById('drawer-root').innerHTML = '';
  },
};

document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape') return;
  if (document.getElementById('modal-root').innerHTML) document.getElementById('modal-root').innerHTML = '';
  else drawer.close();
});

/* =====================================================================
 * Dialogs — confirmation, reasons, and forms (one component)
 * ===================================================================== */

/**
 * dialog({ title, message, fields, confirmLabel, danger, onSubmit(values) })
 * Resolves to onSubmit's result, or null if cancelled. If onSubmit throws,
 * the error is shown inside the dialog and it stays open — so a server
 * refusal (e.g. "needs 3 photos") is read in context, not lost in a toast.
 */
function dialog({ title, message = '', fields = [], confirmLabel = 'Confirm', danger = false, onSubmit }) {
  return new Promise((resolve) => {
    const root = document.getElementById('modal-root');
    const fieldHtml = fields
      .map((f) => {
        const id = `f_${f.name}`;
        const req = f.required ? ' *' : '';
        let input;
        if (f.type === 'textarea') {
          input = `<textarea id="${id}" placeholder="${esc(f.placeholder || '')}">${esc(f.value || '')}</textarea>`;
        } else if (f.type === 'select') {
          input = `<select id="${id}">${f.options
            .map(([v, l]) => `<option value="${esc(v)}" ${String(f.value ?? '') === String(v) ? 'selected' : ''}>${esc(l)}</option>`)
            .join('')}</select>`;
        } else if (f.type === 'checkbox') {
          return `<div class="field"><label style="display:flex;gap:8px;align-items:center;font-weight:500">
            <input id="${id}" type="checkbox" style="width:auto" ${f.value ? 'checked' : ''}> ${esc(f.label)}</label></div>`;
        } else if (f.type === 'multi') {
          return `<div class="field"><label>${esc(f.label)}${req}</label><div style="display:flex;gap:14px">${f.options
            .map(([v, l]) => `<label style="display:flex;gap:6px;align-items:center;font-weight:500">
              <input type="checkbox" style="width:auto" data-multi="${esc(f.name)}" value="${esc(v)}"
              ${(f.value || []).includes(v) ? 'checked' : ''}> ${esc(l)}</label>`)
            .join('')}</div></div>`;
        } else {
          input = `<input id="${id}" type="${f.type || 'text'}" placeholder="${esc(f.placeholder || '')}" value="${esc(f.value ?? '')}">`;
        }
        return `<div class="field"><label for="${id}">${esc(f.label)}${req}</label>${input}${
          f.help ? `<div class="help">${esc(f.help)}</div>` : ''}</div>`;
      })
      .join('');

    root.innerHTML = `
      <div class="modal-backdrop">
        <div class="modal" role="dialog" aria-label="${esc(title)}">
          <h3>${esc(title)}</h3>
          ${message ? `<div class="modal-msg">${message}</div>` : ''}
          <div class="error-msg" hidden></div>
          <form>${fieldHtml}
            <div class="modal-actions">
              <button type="button" class="btn-ghost" data-cancel>Cancel</button>
              <button type="submit" class="${danger ? 'btn-danger' : 'btn-primary inline'}">${esc(confirmLabel)}</button>
            </div>
          </form>
        </div>
      </div>`;

    const errEl = root.querySelector('.error-msg');
    const close = (value) => { root.innerHTML = ''; resolve(value); };
    root.querySelector('[data-cancel]').addEventListener('click', () => close(null));
    root.querySelector('form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const values = {};
      for (const f of fields) {
        if (f.type === 'multi') {
          values[f.name] = [...root.querySelectorAll(`[data-multi="${f.name}"]:checked`)].map((c) => c.value);
        } else if (f.type === 'checkbox') {
          values[f.name] = root.querySelector(`#f_${f.name}`).checked;
        } else {
          values[f.name] = root.querySelector(`#f_${f.name}`).value.trim();
        }
        const v = values[f.name];
        if (f.required && (v === '' || (Array.isArray(v) && v.length === 0))) {
          errEl.textContent = `${f.label} is required.`;
          errEl.hidden = false;
          return;
        }
      }
      const btn = root.querySelector('button[type=submit]');
      btn.disabled = true;
      try {
        const result = onSubmit ? await onSubmit(values) : values;
        close(result ?? true);
      } catch (err) {
        errEl.textContent = err.message;
        errEl.hidden = false;
        btn.disabled = false;
      }
    });
    root.querySelector('input, textarea, select')?.focus();
  });
}

/* =====================================================================
 * Auth
 * ===================================================================== */

const loginEl = document.getElementById('login');
const appEl = document.getElementById('app');
const loginErr = document.getElementById('login-error');

function showLoginError(message) {
  loginErr.textContent = message;
  loginErr.hidden = false;
}

document.getElementById('phone-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  loginErr.hidden = true;
  pendingPhone = document.getElementById('phone').value.trim();
  try {
    await api('/auth/otp/request', { method: 'POST', body: { phone: pendingPhone } });
    document.getElementById('phone-form').hidden = true;
    document.getElementById('code-form').hidden = false;
    document.getElementById('code').focus();
  } catch (err) {
    showLoginError(err.message);
  }
});

document.getElementById('code-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  loginErr.hidden = true;
  try {
    const result = await api('/auth/otp/verify', {
      method: 'POST',
      body: { phone: pendingPhone, code: document.getElementById('code').value.trim() },
    });
    token = result.token;
    localStorage.setItem(TOKEN_KEY, token);
    localStorage.setItem(PHONE_KEY, pendingPhone);
    await api('/admin/me'); // server-side allow-list check
    enterConsole();
  } catch (err) {
    if (err.status === 403) {
      showLoginError('That number signed in, but it is not an admin (not in ADMIN_PHONES).');
      token = null;
      localStorage.removeItem(TOKEN_KEY);
    } else showLoginError(err.message);
  }
});

document.getElementById('back-btn').addEventListener('click', () => {
  document.getElementById('code-form').hidden = true;
  document.getElementById('phone-form').hidden = false;
  loginErr.hidden = true;
});

document.getElementById('logout-btn').addEventListener('click', signOut);

function signOut() {
  token = null;
  localStorage.removeItem(TOKEN_KEY);
  appEl.hidden = true;
  loginEl.hidden = false;
  drawer.close();
  document.getElementById('code-form').hidden = true;
  document.getElementById('phone-form').hidden = false;
}

/* =====================================================================
 * Router & navigation
 * ===================================================================== */

const VIEWS = [];
const view = (id, label, group, render, countKey) => VIEWS.push({ id, label, group, render, countKey });
const main = document.getElementById('main');

// Sidebar order (and grouping) is fixed here, independent of the order views
// are registered in below.
const NAV_ORDER = ['overview', 'users', 'listeners', 'kyc', 'content', 'calls', 'wallet', 'payouts', 'reports', 'audit', 'system'];

function renderNav() {
  VIEWS.sort((a, b) => NAV_ORDER.indexOf(a.id) - NAV_ORDER.indexOf(b.id));
  let html = '';
  let group = null;
  for (const v of VIEWS) {
    if (v.group !== group) {
      group = v.group;
      html += `<div class="nav-group">${esc(group)}</div>`;
    }
    html += `<button class="nav-item" data-view="${v.id}">${esc(v.label)}${
      v.countKey ? `<span class="nav-count" id="count-${v.countKey}" data-count="0"></span>` : ''}</button>`;
  }
  const nav = document.getElementById('nav');
  nav.innerHTML = html;
  nav.addEventListener('click', (e) => {
    const b = e.target.closest('[data-view]');
    if (b) location.hash = `#/${b.dataset.view}`;
  });
}

function go(id) {
  location.hash = `#/${id}`;
}

function route() {
  const id = (location.hash.replace(/^#\/?/, '') || 'overview').split('/')[0];
  const v = VIEWS.find((x) => x.id === id) || VIEWS[0];
  document.querySelectorAll('.nav-item').forEach((b) => b.classList.toggle('active', b.dataset.view === v.id));
  drawer.close();
  main.innerHTML = '';
  v.render(main);
}
window.addEventListener('hashchange', route);

function head(title, sub, actionsHtml = '') {
  return `<div class="view-head"><div><h1>${esc(title)}</h1>${sub ? `<p class="view-sub">${esc(sub)}</p>` : ''}</div>
    <div class="view-actions">${actionsHtml}</div></div>`;
}

async function refreshCounts() {
  try {
    const s = await api('/admin/stats');
    const set = (key, n) => {
      const el = document.getElementById(`count-${key}`);
      if (el) { el.textContent = n; el.dataset.count = n; }
    };
    set('kyc', s.pending_kyc);
    set('payouts', s.pending_payouts);
    set('reports', s.open_reports);
    return s;
  } catch {
    return null;
  }
}

async function enterConsole() {
  loginEl.hidden = true;
  appEl.hidden = false;
  document.getElementById('admin-phone').textContent = localStorage.getItem(PHONE_KEY) || '';
  if (!document.getElementById('nav').children.length) renderNav();
  refreshCounts();
  route();
}

/* =====================================================================
 * Shared detail openers (usable from any view)
 * ===================================================================== */

async function changeUserStatus(user, status) {
  const suspend = status === 'suspended';
  return dialog({
    title: suspend ? `Suspend ${user.name || user.phone}?` : `Restore ${user.name || user.phone}?`,
    message: suspend
      ? 'They lose access on their next request and disappear from discovery. This is recorded in the audit log.'
      : 'They regain access immediately. This is recorded in the audit log.',
    fields: [{ name: 'reason', label: 'Reason', type: 'textarea', required: true }],
    confirmLabel: suspend ? 'Suspend account' : 'Restore account',
    danger: suspend,
    onSubmit: (v) => api(`/admin/users/${user.id}/status`, { method: 'POST', body: { status, reason: v.reason } }),
  });
}

/* ---------- Permanent deletion ---------- */

const countList = (obj) => Object.entries(obj)
  .map(([k, v]) => `<li>${esc(k.replace(/([A-Z])/g, ' $1').toLowerCase())}: <b>${esc(typeof v === 'number' ? num(v) : String(v ?? '—'))}</b></li>`)
  .join('');

/**
 * Permanently deletes an account after showing exactly what goes and what
 * stays. The server re-checks everything (admin, blockers, typed id); this
 * dialog only makes the consequences impossible to miss.
 */
async function deleteAccount(id, label) {
  let preview;
  try {
    preview = await api(`/admin/users/${id}/deletion-preview`);
  } catch (err) {
    toast(`Could not load the deletion preview: ${err.message}`, false);
    return null;
  }
  if (preview.blockers.length) {
    await dialog({
      title: `${label} cannot be deleted yet`,
      message: `<ul class="del-list">${preview.blockers.map((b) => `<li>${esc(b.message)}</li>`).join('')}</ul>`,
      confirmLabel: 'OK',
    });
    return null;
  }
  const result = await dialog({
    title: `Permanently delete ${label}?`,
    message: `<b class="del-warn">This cannot be undone.</b>
      <div class="del-cols">
        <div><h4>Deleted (rows and stored files)</h4><ul class="del-list">${countList(preview.deleted)}</ul></div>
        <div><h4>Anonymised</h4><ul class="del-list">${countList(preview.anonymized)}</ul></div>
        <div><h4>Retained for accounting and audit</h4><ul class="del-list">${countList(preview.retained)}</ul></div>
      </div>`,
    fields: [
      { name: 'reason', label: 'Reason (recorded in the audit log)', type: 'textarea', required: true },
      { name: 'confirm', label: `Type the account id (${id}) to confirm`, required: true },
    ],
    confirmLabel: 'Delete permanently',
    danger: true,
    onSubmit: (v) => api(`/admin/users/${id}`, { method: 'DELETE', body: { reason: v.reason, confirm: v.confirm } }),
  });
  if (result && result.status === 'deleted') {
    const files = Object.values(result.storageObjectsRemoved).reduce((a, b) => a + b, 0);
    toast(`Account #${id} deleted — ${files} stored file(s) removed, financial history kept (audit #${result.auditId})`, true, 9000);
  }
  return result;
}

/** Permanently deletes one upload (post, creator photo or chat photo). */
async function deleteUpload(kind, id) {
  const spec = {
    post: { path: `/admin/posts/${id}`, what: `post #${id}`, note: 'The post and its image/video file are deleted. Use "Remove" instead if it may need restoring.' },
    photo: { path: `/admin/listener-photos/${id}`, what: `creator photo #${id}`, note: 'The photo and its file are deleted. A creator left below the photo minimum is taken offline.' },
    chat: { path: `/admin/chat-media/${id}`, what: `chat photo (message #${id})`, note: 'The message, its reactions and the stored image are deleted from the conversation.' },
  }[kind];
  const result = await dialog({
    title: `Permanently delete ${spec.what}?`,
    message: `<b class="del-warn">This cannot be undone.</b> ${esc(spec.note)}`,
    fields: [{ name: 'reason', label: 'Reason (recorded in the audit log)', type: 'textarea', required: true }],
    confirmLabel: 'Delete permanently',
    danger: true,
    onSubmit: (v) => api(spec.path, { method: 'DELETE', body: { reason: v.reason } }),
  });
  if (result && result.deleted) {
    toast(`Deleted ${spec.what} (${result.storageObjectsRemoved} file removed${result.takenOffline ? '; creator taken offline' : ''})`, true, 9000);
  }
  return result;
}

/** The "Uploads" panel in a user drawer: every post, creator photo and chat
 * photo the account owns, each with its own permanent delete. */
async function renderUploads(host, userId) {
  host.innerHTML = '<div class="sub">Loading uploads…</div>';
  let up;
  try {
    up = await api(`/admin/users/${userId}/uploads`);
  } catch (err) {
    host.innerHTML = `<div class="sub">! ${esc(err.message)}</div>`;
    return;
  }
  const tile = (media, meta, kind, id) => `
    <div class="upload-tile">${media}<div class="sub">${meta}</div>
      ${kind === 'chat' ? `<button class="btn-ghost btn-sm" data-view-chat="${id}">View photo</button>` : ''}
      <button class="btn-danger btn-sm" data-del="${kind}" data-id="${id}">Delete permanently</button></div>`;
  const posts = up.posts.map((p) => tile(postPreview(p), `Post #${p.id} · ${badge(p.media_type)} ${p.status !== 'active' ? badge(p.status) : ''}`, 'post', p.id)).join('');
  const photos = up.photos.map((p) => tile(
    p.url ? `<img src="${esc(p.url)}" alt="" class="thumb" style="width:64px;height:64px" loading="lazy">` : postPreview({}),
    `Photo #${p.id}`, 'photo', p.id)).join('');
  const chat = up.chatPhotos.map((m) => tile(
    '<div class="ph" style="width:64px;height:64px;border-radius:8px;display:grid;place-items:center;color:var(--text-faint);font-size:11px;border:1px solid var(--border)">private</div>',
    `Message #${m.id} · to #${m.other_user_id} · ${when(m.created_at)}`, 'chat', m.id)).join('');
  host.innerHTML = `
    <h4>Feed posts (${up.posts.length})</h4><div class="upload-grid">${posts || '<span class="sub">None.</span>'}</div>
    <h4>Creator photos (${up.photos.length})</h4><div class="upload-grid">${photos || '<span class="sub">None.</span>'}</div>
    <h4>Chat photos sent (${up.chatPhotos.length}) <span class="sub">— not previewed; private messages</span></h4>
    <div class="upload-grid">${chat || '<span class="sub">None.</span>'}</div>`;
  host.querySelectorAll('[data-del]').forEach((b) => b.addEventListener('click', async () => {
    if (await deleteUpload(b.dataset.del, b.dataset.id)) renderUploads(host, userId);
  }));
  host.querySelectorAll('[data-view-chat]').forEach((b) => b.addEventListener('click', () => openChatPhoto(b.dataset.viewChat, userId)));
}

/** Inspector for ONE chat photo: the image itself (a 5-minute signed URL;
 * every view is audit-logged server-side), who sent it to whom, and the
 * permanent delete. Opened only by an explicit click — chat photos are
 * never previewed in bulk. */
function openChatPhoto(messageId, backToUserId) {
  drawer.open(`Chat photo · message #${messageId}`, async (body) => {
    const m = await api(`/admin/chat-media/${messageId}`);
    body.innerHTML = `
      <div class="drawer-actions">
        <button class="btn-danger btn-sm" data-act="delete">Delete permanently</button>
        ${backToUserId ? '<button class="btn-ghost btn-sm" data-act="back">Back to user</button>' : ''}
      </div>
      <div class="panel">${m.url
        ? `<img src="${esc(m.url)}" alt="chat photo" style="max-width:100%;max-height:480px;border-radius:10px;display:block">`
        : '<div class="empty">The stored image could not be loaded.</div>'}</div>
      <div class="panel"><h3>Message</h3>${kv([
        ['Sent by', `${esc(m.sender.name || '—')} #${m.sender.id}`],
        ['Sent to', `${esc(m.recipient.name || '—')} #${m.recipient.id}`],
        ['Conversation', `#${m.conversationId}`],
        ['Sent', esc(fmtDate(m.createdAt))],
        ['Note', 'Private message. This view was recorded in the audit log.'],
      ])}</div>`;
    body.querySelector('[data-act=delete]').addEventListener('click', async () => {
      if (!(await deleteUpload('chat', m.id))) return;
      if (backToUserId) openUser(backToUserId); else drawer.close();
    });
    body.querySelector('[data-act=back]')?.addEventListener('click', () => openUser(backToUserId));
  });
}

/** A visible per-row Delete for account tables. Admin accounts and
 * already-deleted ones get none (the server refuses admins regardless). */
function rowDeleteButton(id, label, { isAdmin = false, deleted = false } = {}) {
  if (isAdmin) return '<span class="sub">admin</span>';
  if (deleted) return '<span class="sub">deleted</span>';
  return `<button class="btn-danger btn-sm" data-row-del="${id}" data-label="${esc(label || `#${id}`)}" title="Permanently delete account #${id}">Delete</button>`;
}

function wireRowDeletes(tbody, onDone) {
  tbody.querySelectorAll('[data-row-del]').forEach((b) => b.addEventListener('click', async (e) => {
    e.stopPropagation();
    if (await deleteAccount(b.dataset.rowDel, b.dataset.label)) onDone();
  }));
}

function openUser(id) {
  drawer.open(`User #${id}`, async (body) => {
    const u = await api(`/admin/users/${id}`);
    const L = u.listener;
    body.innerHTML = `
      <div class="drawer-actions">
        ${u.status === 'active' && !u.isAdmin ? '<button class="btn-danger btn-sm" data-act="suspend">Suspend account</button>' : ''}
        ${u.status === 'suspended' ? '<button class="btn-ok btn-sm" data-act="restore">Restore account</button>' : ''}
        ${L ? '<button class="btn-ghost btn-sm" data-act="listener">Open creator profile</button>' : ''}
        ${typeof openWallet === 'function' ? '<button class="btn-ghost btn-sm" data-act="wallet">Wallet & ledger</button>' : ''}
        ${!u.isAdmin ? '<button class="btn-danger btn-sm" data-act="delete">Delete permanently</button>' : ''}
      </div>
      <div class="cols-2">
        <div class="panel"><h3>Profile</h3>${kv([
          ['Name', esc(u.name || '—')],
          ['Phone', `<span class="mono">${esc(u.phone)}</span>${u.isAdmin ? ' ' + badge('admin') : ''}`],
          ['Account status', badge(u.status)],
          ['Role', badge(u.role)],
          ['Language / gender', `${esc(u.language || '—')} / ${esc(u.gender || '—')}`],
          ['Joined', esc(fmtDate(u.createdAt))],
          ['Last sign-in', when(u.lastActive)],
          ['Free trial', u.freeTrialUsed ? 'used' : 'available'],
        ])}</div>
        <div class="panel"><h3>Wallet & activity</h3>${kv([
          ['Coin balance', coins(u.wallet.coinBalance)],
          ['Calls (total)', num(u.callStats.total)],
          ['As caller / listener', `${num(u.callStats.as_caller)} / ${num(u.callStats.as_listener)}`],
          ['Coins spent on calls', coins(u.callStats.coins_spent)],
          ['Reports against', num(u.moderation.reportsAgainst)],
          ['Blocks given / received', `${u.moderation.blocksGiven} / ${u.moderation.blocksReceived}`],
        ])}</div>
      </div>
      ${L ? `<div class="panel"><h3>Creator / listener</h3>${kv([
        ['KYC', badge(L.kycStatus)],
        ['Photos', photosBadge(L.photoCount)],
        ['Active (eligible)', L.eligible ? badge('eligible') : blockerBadges(L.blockers)],
        ['Availability', `${onlineDot(L.isOnline)} ${L.isOnline ? 'online' : 'offline'}${L.isBusy ? ' · busy' : ''}`],
        ['Earnings balance / lifetime', `${rupees(L.earningsBalance)} / ${rupees(L.lifetimeEarnings)}`],
      ])}</div>` : ''}
      <div class="panel"><h3>Recent coin ledger</h3>${miniTable([
        { label: 'When', render: (r) => when(r.created_at) },
        { label: 'Type', render: (r) => badge(r.reason, 'grey') },
        { label: 'Change', num: true, render: (r) => signed(r.delta) },
        { label: 'Balance', num: true, render: (r) => coins(r.balance_after) },
        { label: 'Ref', render: (r) => `<span class="mono">${esc(r.ref_id || '—')}</span>` },
      ], u.ledger, 'No ledger entries.')}</div>
      <div class="panel"><h3>Recent calls</h3>${miniTable([
        { label: '#', render: (r) => r.id },
        { label: 'Side', render: (r) => badge(r.side, 'grey') },
        { label: 'With', render: (r) => esc(r.other_name || '—') },
        { label: 'Type', render: (r) => badge(r.type) },
        { label: 'Duration', render: (r) => duration(r.started_at, r.ended_at) },
        { label: 'Coins', num: true, render: (r) => coins(r.coins_spent) },
        { label: 'Status', render: (r) => badge(r.status) },
        { label: 'When', render: (r) => when(r.created_at) },
      ], u.calls, 'No calls.')}</div>
      <div class="panel"><h3>Reports</h3>${miniTable([
        { label: '#', render: (r) => `<a href="#" data-report="${r.id}">${r.id}</a>` },
        { label: 'Direction', render: (r) => badge(r.direction === 'against' ? 'against' : 'filed', r.direction === 'against' ? 'red' : 'grey') },
        { label: 'Other party', render: (r) => esc(r.other_name || '—') },
        { label: 'Reason', render: (r) => esc(r.reason) },
        { label: 'Status', render: (r) => badge(r.status) },
        { label: 'When', render: (r) => when(r.created_at) },
      ], u.reports, 'No reports.')}</div>
      <div class="panel"><h3>Uploads</h3><div data-uploads></div></div>
      <div class="panel"><h3>Admin history</h3>${timeline(u.history)}</div>`;

    renderUploads(body.querySelector('[data-uploads]'), u.id);
    body.querySelector('[data-act=delete]')?.addEventListener('click', async () => {
      if (await deleteAccount(u.id, u.name || `user #${u.id}`)) drawer.refresh();
    });
    body.querySelector('[data-act=suspend]')?.addEventListener('click', async () => {
      if (await changeUserStatus(u, 'suspended')) { toast('Account suspended'); drawer.refresh(); }
    });
    body.querySelector('[data-act=restore]')?.addEventListener('click', async () => {
      if (await changeUserStatus(u, 'active')) { toast('Account restored'); drawer.refresh(); }
    });
    body.querySelector('[data-act=listener]')?.addEventListener('click', () => openListener(u.id));
    body.querySelector('[data-act=wallet]')?.addEventListener('click', () => openWallet(u.id));
    body.querySelectorAll('[data-report]').forEach((a) => a.addEventListener('click', (e) => {
      e.preventDefault();
      openReport(a.dataset.report);
    }));
  });
}

async function reviewKyc(listener, approve, onDone) {
  const ok = await dialog({
    title: approve ? `Approve ${listener.name || 'application'}?` : `Reject ${listener.name || 'application'}?`,
    message: approve
      ? 'Approval makes this creator active (discoverable and callable) — the server re-checks photos, documents and profile first.'
      : 'They will be notified with your reason and taken offline. Recorded in the audit log.',
    fields: approve
      ? [{ name: 'note', label: 'Review note (internal)', type: 'textarea' }]
      : [
          { name: 'reason', label: 'Rejection reason (sent to the creator)', type: 'textarea', required: true },
          { name: 'note', label: 'Internal note', type: 'textarea' },
        ],
    confirmLabel: approve ? 'Approve' : 'Reject',
    danger: !approve,
    onSubmit: (v) =>
      api(`/admin/kyc/${listener.id}`, {
        method: 'POST',
        body: { approve, reason: v.reason || undefined, note: v.note || undefined },
      }),
  });
  if (ok) {
    toast(approve ? 'Application approved' : 'Application rejected');
    refreshCounts();
    onDone?.();
  }
}

function openListener(id) {
  drawer.open(`Creator #${id}`, async (body) => {
    const l = await api(`/admin/listeners/${id}`);
    const k = l.kyc;
    body.innerHTML = `
      <div class="drawer-actions">
        ${k.status === 'pending' ? '<button class="btn-ok btn-sm" data-act="approve">Approve application</button><button class="btn-danger btn-sm" data-act="reject">Reject</button>' : ''}
        ${k.status === 'approved' ? '<button class="btn-danger btn-sm" data-act="reject">Revoke approval</button>' : ''}
        <button class="btn-ghost btn-sm" data-act="user">Open user account</button>
        <button class="btn-danger btn-sm" data-act="delete">Delete permanently</button>
      </div>
      <div class="cols-2">
        <div class="panel"><h3>Status</h3>${kv([
          ['Application', badge(l.applicationStatus)],
          ['Active (eligible)', l.eligible ? badge('eligible') : blockerBadges(l.blockers)],
          ['Account', badge(l.accountStatus)],
          ['Availability', `${onlineDot(l.availability.isOnline)} ${l.availability.isOnline ? 'online' : 'offline'}${l.availability.isBusy ? ' · busy' : ''}`],
          ['Photos', `${photosBadge(l.photoCount, l.minPhotos)} <span class="sub">max ${l.maxPhotos}</span>`],
        ])}</div>
        <div class="panel"><h3>Profile</h3>${kv([
          ['Name', esc(l.name || '—')],
          ['Phone', `<span class="mono">${esc(l.phone)}</span>`],
          ['Languages', esc((l.languages || []).join(', '))],
          ['Capabilities', `${l.capabilities.acceptsAudio ? badge('audio') : ''} ${l.capabilities.acceptsVideo ? badge('video') : ''}`],
          ['Rates (coins/min)', `audio ${l.capabilities.audioRate} · video ${l.capabilities.videoRate}`],
          ['Rating', `${l.rating.toFixed(2)} (${l.ratingCount})`],
          ['Bio', esc(l.bio || '—')],
        ])}</div>
      </div>
      <div class="panel"><h3>Photos (${l.photos.length})</h3>${l.photos.length
        ? `<div class="photo-grid">${l.photos.map((p) => `<div class="photo-cell">${p.url
            ? `<a href="${esc(p.url)}" target="_blank" rel="noopener"><img src="${esc(p.url)}" alt="photo ${p.id}" loading="lazy"></a>`
            : '<div class="ph"></div>'}<button class="btn-danger btn-sm" data-photo-del="${p.id}">Delete photo #${p.id}</button></div>`).join('')}</div>`
        : '<div class="empty" style="padding:14px">No photos uploaded yet.</div>'}</div>
      <div class="panel"><h3>KYC (admin only)</h3>${kv([
        ['Status', badge(k.status)],
        ['Legal name', esc(k.name || '—')],
        ['Document', k.docUrl ? `<a href="${esc(k.docUrl)}" target="_blank" rel="noopener noreferrer">open document ↗</a>` : '—'],
        ['UPI', `<span class="mono">${esc(k.upiId || '—')}</span>`],
        ['Submitted', esc(fmtDate(k.submittedAt))],
        ['Reviewed', k.reviewedAt ? `${esc(fmtDate(k.reviewedAt))} by <span class="mono">${esc(k.reviewedBy || '—')}</span>` : '—'],
        ['Review note', esc(k.reviewNote || '—')],
      ])}</div>
      <div class="cols-2">
        <div class="panel"><h3>Call stats</h3>${kv([
          ['Calls', num(l.callStats.total)],
          ['Completed (billed)', num(l.callStats.completed)],
          ['Audio / video', `${l.callStats.audio} / ${l.callStats.video}`],
          ['Billed minutes', num(l.callStats.billed_minutes)],
          ['Last call', when(l.callStats.last_call_at)],
        ])}</div>
        <div class="panel"><h3>Earnings</h3>${kv([
          ['Withdrawable balance', rupees(l.earnings.balance)],
          ['Lifetime', rupees(l.earnings.lifetime)],
          ['From calls (sum)', rupees(l.callStats.earned)],
        ])}</div>
      </div>
      <div class="panel"><h3>Recent earnings ledger</h3>${miniTable([
        { label: 'When', render: (r) => when(r.created_at) },
        { label: 'Type', render: (r) => badge(r.reason, 'grey') },
        { label: 'Change', num: true, render: (r) => signed(r.delta) },
        { label: 'Balance', num: true, render: (r) => rupees(r.balance_after) },
      ], l.earnings.recent, 'No earnings yet.')}</div>
      <div class="panel"><h3>Reports against (${l.reports.total})</h3>${miniTable([
        { label: '#', render: (r) => `<a href="#" data-report="${r.id}">${r.id}</a>` },
        { label: 'Reporter', render: (r) => esc(r.reporter_name || '—') },
        { label: 'Reason', render: (r) => esc(r.reason) },
        { label: 'Status', render: (r) => badge(r.status) },
        { label: 'When', render: (r) => when(r.created_at) },
      ], l.reports.recent, 'No reports.')}</div>
      <div class="panel"><h3>Admin history</h3>${timeline(l.history)}</div>`;

    body.querySelector('[data-act=approve]')?.addEventListener('click', () => reviewKyc(l, true, () => drawer.refresh()));
    body.querySelector('[data-act=reject]')?.addEventListener('click', () => reviewKyc(l, false, () => drawer.refresh()));
    body.querySelector('[data-act=user]').addEventListener('click', () => openUser(l.id));
    body.querySelectorAll('[data-photo-del]').forEach((b) => b.addEventListener('click', async () => {
      if (await deleteUpload('photo', b.dataset.photoDel)) drawer.refresh();
    }));
    body.querySelector('[data-act=delete]').addEventListener('click', async () => {
      if (await deleteAccount(l.id, l.name || `creator #${l.id}`)) drawer.refresh();
    });
    body.querySelectorAll('[data-report]').forEach((a) => a.addEventListener('click', (e) => {
      e.preventDefault();
      openReport(a.dataset.report);
    }));
  });
}

function openReport(id) {
  drawer.open(`Report #${id}`, async (body) => {
    const r = await api(`/admin/reports/${id}`);
    const unresolved = ['open', 'reviewing'].includes(r.status);
    body.innerHTML = `
      <div class="drawer-actions">
        ${r.status === 'open' ? '<button class="btn-ghost btn-sm" data-act="review">Mark reviewing</button>' : ''}
        ${unresolved ? '<button class="btn-ok btn-sm" data-act="resolve">Resolve</button><button class="btn-ghost btn-sm" data-act="dismiss">Dismiss</button>' : ''}
        ${r.reported_status === 'active' ? '<button class="btn-danger btn-sm" data-act="suspend">Suspend reported user</button>' : ''}
      </div>
      <div class="panel"><h3>Report</h3>${kv([
        ['Status', badge(r.status)],
        ['Reason', badge(r.reason, 'rose')],
        ['Target', r.targetType === 'call' ? `${badge('call')} call #${r.call_id}` : badge('user', 'grey')],
        ['Description', esc(r.details || '—')],
        ['Filed', esc(fmtDate(r.created_at))],
        ['Resolved', r.resolved_at ? `${esc(fmtDate(r.resolved_at))} by <span class="mono">${esc(r.resolved_by_phone || '—')}</span>` : '—'],
        ['Moderation note', esc(r.resolution_note || '—')],
      ])}</div>
      <div class="cols-2">
        <div class="panel"><h3>Reported</h3>${kv([
          ['User', `<a href="#" data-user="${r.reported_id}">${esc(r.reported_name || '—')} #${r.reported_id}</a>`],
          ['Phone', `<span class="mono">${esc(r.reported_phone)}</span>`],
          ['Account', badge(r.reported_status)],
          ['Role', badge(r.reported_role)],
        ])}</div>
        <div class="panel"><h3>Reporter</h3>${kv([
          ['User', `<a href="#" data-user="${r.reporter_id}">${esc(r.reporter_name || '—')} #${r.reporter_id}</a>`],
          ['Phone', `<span class="mono">${esc(r.reporter_phone)}</span>`],
          ['Account', badge(r.reporter_status)],
        ])}</div>
      </div>
      ${r.call ? `<div class="panel"><h3>Linked call #${r.call.id}</h3>${kv([
        ['Type / status', `${badge(r.call.type)} ${badge(r.call.status)}`],
        ['Duration', duration(r.call.started_at, r.call.ended_at)],
        ['Billed minutes', num(r.call.billed_minutes)],
        ['Coins / earned', `${coins(r.call.coins_spent)} / ${rupees(r.call.listener_earned)}`],
        ['End reason', esc(r.call.end_reason || '—')],
        ['When', esc(fmtDate(r.call.created_at))],
      ])}</div>` : ''}
      <div class="panel"><h3>Other reports against this user</h3>${miniTable([
        { label: '#', render: (x) => `<a href="#" data-report="${x.id}">${x.id}</a>` },
        { label: 'Reporter', render: (x) => esc(x.reporter_name || '—') },
        { label: 'Reason', render: (x) => esc(x.reason) },
        { label: 'Status', render: (x) => badge(x.status) },
        { label: 'When', render: (x) => when(x.created_at) },
      ], r.otherReportsAgainst, 'None.')}</div>
      <div class="panel"><h3>Action history</h3>${timeline(r.history)}</div>`;

    const act = (action, title, message, danger) => async () => {
      const done = await dialog({
        title,
        message,
        fields: action === 'review' ? [] : [{ name: 'note', label: 'Moderation note', type: 'textarea', required: true }],
        confirmLabel: title,
        danger,
        onSubmit: (v) => api(`/admin/reports/${r.id}`, { method: 'POST', body: { action, note: v.note || undefined } }),
      });
      if (done) { toast('Report updated'); refreshCounts(); drawer.refresh(); }
    };
    body.querySelector('[data-act=review]')?.addEventListener('click', act('review', 'Mark reviewing', 'Signals that someone is looking at this report.'));
    body.querySelector('[data-act=resolve]')?.addEventListener('click', act('resolve', 'Resolve report', 'Handled — no account action taken.'));
    body.querySelector('[data-act=dismiss]')?.addEventListener('click', act('dismiss', 'Dismiss report', 'Not a violation.'));
    body.querySelector('[data-act=suspend]')?.addEventListener('click', act('suspend', 'Suspend user', 'Resolves this report and suspends the reported account immediately.', true));
    body.querySelectorAll('[data-user]').forEach((a) => a.addEventListener('click', (e) => { e.preventDefault(); openUser(a.dataset.user); }));
    body.querySelectorAll('[data-report]').forEach((a) => a.addEventListener('click', (e) => { e.preventDefault(); openReport(a.dataset.report); }));
  });
}

/* =====================================================================
 * Views
 * ===================================================================== */

view('overview', 'Overview', 'Operate', async (el) => {
  el.innerHTML = head('Overview', 'Live platform state and today’s totals.', '<button class="btn-ghost btn-sm" data-r>Refresh</button>') +
    '<div class="stat-grid" id="stats"><div class="empty">Loading…</div></div>';
  const load = async () => {
    const s = await refreshCounts();
    if (!s) { el.querySelector('#stats').innerHTML = empty('!', 'Could not load stats.'); return; }
    const card = (label, value, opts = {}) =>
      `<div class="stat ${opts.attn ? 'attn' : ''} ${opts.go ? 'clickable' : ''}" ${opts.go ? `data-go="${opts.go}"` : ''}>
        <div class="stat-label">${esc(label)}</div><div class="stat-value ${opts.money ? 'money' : ''}">${value}</div></div>`;
    el.querySelector('#stats').innerHTML = [
      card('Pending KYC', num(s.pending_kyc), { attn: s.pending_kyc > 0, go: 'kyc' }),
      card('Open reports', num(s.open_reports), { attn: s.open_reports > 0, go: 'reports' }),
      card('Pending payouts', num(s.pending_payouts), { attn: s.pending_payouts > 0, go: 'payouts' }),
      card('Active users', num(s.active_users), { go: 'users' }),
      card('Suspended users', num(s.suspended_users), { go: 'users' }),
      card('New users today', num(s.new_users_today), { go: 'users' }),
      card('Active creators', num(s.active_listeners), { go: 'listeners' }),
      card('Approved (KYC)', num(s.approved_listeners), { go: 'listeners' }),
      card('Online now', num(s.online_listeners), { go: 'listeners' }),
      card('Live calls', num(s.live_calls), { go: 'calls' }),
      card('Calls today', num(s.calls_today), { go: 'calls' }),
      card('Coins spent today', num(s.coins_spent_today), { money: true }),
      card('Coins purchased today', num(s.coins_purchased_today), { money: true }),
      card('Platform revenue today', num(s.platform_revenue_today), { money: true }),
      card('Admin actions today', num(s.admin_actions_today), { go: 'audit' }),
    ].join('');
    el.querySelectorAll('[data-go]').forEach((c) => c.addEventListener('click', () => {
      if (VIEWS.some((v) => v.id === c.dataset.go)) go(c.dataset.go);
    }));
  };
  el.querySelector('[data-r]').addEventListener('click', load);
  load();
});

view('users', 'Users', 'Operate', (el) => {
  el.innerHTML = head('Users', 'Every account. Click a row for the full profile, wallet, calls, reports and admin history.',
    '<button class="btn-primary inline" data-create>+ Create user</button>') + '<div id="t"></div>';
  const table = dataTable(el.querySelector('#t'), {
    endpoint: '/admin/users',
    search: 'Name, phone or #id…',
    sort: 'created',
    dateRange: true,
    filters: [
      { key: 'status', label: 'Status', options: [['active', 'Active'], ['suspended', 'Suspended'], ['deleted', 'Deleted']] },
      { key: 'role', label: 'Role', options: [['user', 'Caller'], ['listener', 'Listener'], ['both', 'Both']] },
      { key: 'listener', label: 'Creator', options: [['none', 'Not a creator'], ['eligible', 'Active creator'], ['pending', 'KYC pending'], ['approved', 'KYC approved'], ['rejected', 'KYC rejected'], ['unsubmitted', 'Draft']] },
    ],
    columns: [
      { label: '#', sort: 'id', render: (r) => r.id },
      { label: 'Name', sort: 'name', render: (r) => `${esc(r.name || '—')}${r.isAdmin ? ' ' + badge('admin') : ''}<span class="sub mono">${esc(r.phone)}</span>` },
      { label: 'Status', sort: 'status', render: (r) => badge(r.status) },
      { label: 'Role', render: (r) => badge(r.role) },
      { label: 'Creator', render: (r) => (r.listener ? `${badge(r.listener.kycStatus)} ${photosBadge(r.listener.photoCount)} ${onlineDot(r.listener.isOnline)}` : '—') },
      { label: 'Coins', sort: 'balance', num: true, render: (r) => coins(r.coinBalance) },
      { label: 'Joined', sort: 'created', render: (r) => when(r.createdAt) },
      { label: 'Last sign-in', sort: 'lastActive', render: (r) => when(r.lastActive) },
      { label: 'Actions', pin: true, render: (r) => rowDeleteButton(r.id, r.name || r.phone, { isAdmin: r.isAdmin, deleted: r.status === 'deleted' }) },
    ],
    onRow: (r) => openUser(r.id),
    afterLoad: (rows, tbody) => wireRowDeletes(tbody, () => table.reload()),
  });
  el.querySelector('[data-create]').addEventListener('click', async () => {
    const created = await dialog({
      title: 'Create user',
      message: 'Creates the account for a phone number. There is no password — the person signs in with an OTP to this number. Recorded in the audit log.',
      fields: [
        { name: 'phone', label: 'Phone (international format)', placeholder: '+919876543210', required: true },
        { name: 'displayName', label: 'Display name' },
        { name: 'language', label: 'Language', type: 'select', options: [['en', 'English'], ['hi', 'Hindi'], ['te', 'Telugu']] },
        { name: 'gender', label: 'Gender', type: 'select', options: [['', '—'], ['female', 'Female'], ['male', 'Male'], ['other', 'Other']] },
        { name: 'reason', label: 'Reason (for the audit log)', type: 'textarea' },
      ],
      confirmLabel: 'Create user',
      onSubmit: (v) => api('/admin/users', {
        method: 'POST',
        body: {
          phone: v.phone,
          displayName: v.displayName || undefined,
          language: v.language || undefined,
          gender: v.gender || undefined,
          reason: v.reason || undefined,
        },
      }),
    });
    if (created) { toast(`User #${created.id} created`); table.reload(); openUser(created.id); }
  });
});

view('listeners', 'Creators / Listeners', 'Operate', (el) => {
  el.innerHTML = head('Creators / Listeners',
    'Active = KYC approved AND at least 3 photos. Approval happens in the KYC queue; creating a creator here starts a draft only.',
    '<button class="btn-primary inline" data-create>+ Create creator</button>') + '<div id="t"></div>';
  const table = dataTable(el.querySelector('#t'), {
    endpoint: '/admin/listeners',
    search: 'Name, phone, legal name or #id…',
    sort: 'created',
    dateRange: true,
    filters: [
      { key: 'eligible', label: 'Active', options: [['true', 'Active'], ['false', 'Not active']] },
      { key: 'kyc', label: 'KYC', options: [['pending', 'Pending'], ['approved', 'Approved'], ['rejected', 'Rejected'], ['unsubmitted', 'Not submitted']] },
      { key: 'photos', label: 'Photos', options: [['complete', 'Complete (3+)'], ['incomplete', 'Incomplete']] },
      { key: 'online', label: 'Online', options: [['true', 'Online'], ['false', 'Offline']] },
      { key: 'capability', label: 'Takes', options: [['audio', 'Audio'], ['video', 'Video']] },
      { key: 'language', label: 'Language', options: [['en', 'English'], ['hi', 'Hindi'], ['te', 'Telugu']] },
      { key: 'accountStatus', label: 'Account', options: [['active', 'Active'], ['suspended', 'Suspended'], ['deleted', 'Deleted']] },
    ],
    columns: [
      { label: 'Name', sort: 'name', render: (r) => `${esc(r.name || '—')} <span class="sub mono">${esc(r.phone)} · #${r.id}</span>` },
      { label: 'Application', render: (r) => badge(r.applicationStatus) },
      { label: 'KYC', sort: 'kyc', render: (r) => badge(r.kycStatus) },
      { label: 'Photos', sort: 'photos', render: (r) => photosBadge(r.photoCount, r.minPhotos) },
      { label: 'Online', render: (r) => `${onlineDot(r.isOnline)}${r.isBusy ? ' busy' : ''}` },
      { label: 'Takes', render: (r) => `${r.acceptsAudio ? badge('audio') : ''} ${r.acceptsVideo ? badge('video') : ''}` },
      { label: 'Lang', render: (r) => esc((r.languages || []).join(', ')) },
      { label: 'Earned', sort: 'earnings', num: true, render: (r) => rupees(r.lifetimeEarnings) },
      { label: 'Calls', sort: 'calls', num: true, render: (r) => num(r.totalCalls) },
      { label: 'Rating', sort: 'rating', num: true, render: (r) => r.rating.toFixed(1) },
      { label: 'Account', render: (r) => badge(r.accountStatus) },
      { label: 'Created', sort: 'created', render: (r) => when(r.createdAt) },
      { label: 'Actions', pin: true, render: (r) => rowDeleteButton(r.id, r.name || `creator #${r.id}`, { deleted: r.accountStatus === 'deleted' }) },
    ],
    onRow: (r) => openListener(r.id),
    afterLoad: (rows, tbody) => wireRowDeletes(tbody, () => table.reload()),
  });
  el.querySelector('[data-create]').addEventListener('click', async () => {
    const created = await dialog({
      title: 'Create creator / listener',
      message: 'Creates a DRAFT creator. They are not active until they sign in with OTP, upload at least 3 photos, submit KYC — and you approve the application.',
      fields: [
        { name: 'phone', label: 'Phone (international format)', placeholder: '+919900000000', required: true },
        { name: 'displayName', label: 'Display name', required: true },
        { name: 'bio', label: 'Bio', type: 'textarea' },
        { name: 'languages', label: 'Languages', type: 'multi', options: [['en', 'English'], ['hi', 'Hindi'], ['te', 'Telugu']], value: ['en'], required: true },
        { name: 'acceptsAudio', label: 'Takes audio calls', type: 'checkbox', value: true },
        { name: 'acceptsVideo', label: 'Takes video calls', type: 'checkbox', value: true },
        { name: 'reason', label: 'Reason (for the audit log)', type: 'textarea' },
      ],
      confirmLabel: 'Create draft creator',
      onSubmit: (v) => api('/admin/listeners', {
        method: 'POST',
        body: {
          phone: v.phone,
          displayName: v.displayName,
          bio: v.bio || undefined,
          languages: v.languages,
          acceptsAudio: v.acceptsAudio,
          acceptsVideo: v.acceptsVideo,
          reason: v.reason || undefined,
        },
      }),
    });
    if (created) { toast(`Draft creator #${created.id} created`); table.reload(); openListener(created.id); }
  });
});

view('kyc', 'KYC', 'Operate', (el) => {
  el.innerHTML = head('KYC & applications', 'Oldest first. Approval is refused server-side unless the application is submitted with documents, a name and at least 3 photos.') + '<div id="t"></div>';
  const table = dataTable(el.querySelector('#t'), {
    endpoint: '/admin/kyc',
    search: 'Name, phone or legal name…',
    initial: { status: 'pending' },
    dateRange: true,
    filters: [{ key: 'status', label: 'Status', options: [['pending', 'Pending'], ['approved', 'Approved'], ['rejected', 'Rejected'], ['unsubmitted', 'Not submitted'], ['all', 'Everything']] }],
    columns: [
      { label: 'Applicant', sort: 'name', render: (r) => `${esc(r.name || '—')} <span class="sub mono">${esc(r.phone)} · #${r.id}</span>` },
      { label: 'Submitted', sort: 'submitted', render: (r) => when(r.submittedAt) },
      { label: 'Photos', sort: 'photos', render: (r) => `<div class="thumbs">${r.photos.slice(0, 4).map((p) => p.url
        ? `<a href="${esc(p.url)}" target="_blank" rel="noopener"><img class="thumb" src="${esc(p.url)}" alt="" loading="lazy"></a>` : '').join('')}</div>
        <span class="sub">${photosBadge(r.photoCount, r.minPhotos)}</span>` },
      { label: 'Documents', render: (r) => `${esc(r.kycName || '—')}<span class="sub">${r.docUrl ? `<a href="${esc(r.docUrl)}" target="_blank" rel="noopener noreferrer">document ↗</a>` : 'no document'} · <span class="mono">${esc(r.upiId || '—')}</span></span>` },
      { label: 'Status', render: (r) => badge(r.kycStatus) },
      { label: 'Approvable', render: (r) => blockerBadges(r.approvalBlockers) },
      { label: 'Reviewed', sort: 'reviewed', render: (r) => (r.reviewedAt ? `${when(r.reviewedAt)}<span class="sub mono">${esc(r.reviewedBy || '')}</span>` : '—') },
      { label: '', render: (r) => (r.kycStatus === 'pending'
        ? `<button class="btn-ok btn-sm" data-approve="${r.id}" ${r.approvalBlockers.length ? 'disabled title="Not approvable yet"' : ''}>Approve</button>
           <button class="btn-danger btn-sm" data-reject="${r.id}">Reject</button>` : '') },
    ],
    onRow: (r) => openListener(r.id),
    afterLoad: (rows, tbody) => {
      tbody.querySelectorAll('[data-approve]').forEach((b) => b.addEventListener('click', () =>
        reviewKyc(rows.find((x) => String(x.id) === b.dataset.approve), true, () => table.reload())));
      tbody.querySelectorAll('[data-reject]').forEach((b) => b.addEventListener('click', () =>
        reviewKyc(rows.find((x) => String(x.id) === b.dataset.reject), false, () => table.reload())));
    },
  });
}, 'kyc');

view('reports', 'Reports', 'Safety', (el) => {
  el.innerHTML = head('Reports', 'Unresolved first by default. Every moderation action requires a note and is audit-logged.') + '<div id="t"></div>';
  dataTable(el.querySelector('#t'), {
    endpoint: '/admin/reports',
    search: 'Names, phones, details or #id…',
    initial: { status: 'unresolved' },
    dateRange: true,
    filters: [
      { key: 'status', label: 'Status', options: [['unresolved', 'Unresolved'], ['open', 'Open'], ['reviewing', 'Reviewing'], ['actioned', 'Actioned'], ['dismissed', 'Dismissed']] },
      { key: 'reason', label: 'Reason', options: async () => (await api('/admin/reports/meta')).reasons.map((r) => [r, r]) },
      { key: 'target', label: 'Target', options: [['user', 'User'], ['call', 'Call']] },
    ],
    columns: [
      { label: '#', render: (r) => r.id },
      { label: 'Reported', render: (r) => `${esc(r.reported_name || '—')} ${r.reported_status !== 'active' ? badge(r.reported_status) : ''}<span class="sub mono">${esc(r.reported_phone)}</span>` },
      { label: 'Reporter', render: (r) => `${esc(r.reporter_name || '—')}<span class="sub mono">${esc(r.reporter_phone)}</span>` },
      { label: 'Reason', sort: 'reason', render: (r) => badge(r.reason, 'rose') },
      { label: 'Target', render: (r) => (r.targetType === 'call' ? `${badge('call')} #${r.call_id}` : badge('user', 'grey')) },
      { label: 'Against user', sort: 'againstCount', num: true, render: (r) => num(r.reports_against) },
      { label: 'Status', sort: 'status', render: (r) => badge(r.status) },
      { label: 'Filed', sort: 'created', render: (r) => when(r.created_at) },
    ],
    onRow: (r) => openReport(r.id),
  });
}, 'reports');


view('audit', 'Audit log', 'System', (el) => {
  el.innerHTML = head('Audit log', 'Append-only — the database refuses updates and deletes. Every sensitive admin action lands here.') + '<div id="t"></div>';
  let meta;
  const metaP = () => (meta ||= api('/admin/audit/meta'));
  dataTable(el.querySelector('#t'), {
    endpoint: '/admin/audit',
    search: 'Action, reason, target id, metadata…',
    sort: 'created',
    dateRange: true,
    filters: [
      { key: 'action', label: 'Action', options: async () => (await metaP()).actions.map((a) => [a, a]) },
      { key: 'admin', label: 'Admin', options: async () => (await metaP()).admins.map((a) => [a, a]) },
      { key: 'targetType', label: 'Target', options: async () => (await metaP()).targetTypes.map((a) => [a, a]) },
    ],
    columns: [
      { label: 'When', sort: 'created', render: (r) => `${esc(fmtDate(r.created_at))}` },
      { label: 'Admin', sort: 'admin', render: (r) => `<span class="mono">${esc(r.admin_phone)}</span>` },
      { label: 'Action', sort: 'action', render: (r) => badge(r.action, 'rose') },
      { label: 'Target', sort: 'target', render: (r) => `${esc(r.target_type)} ${r.target_id ? `<span class="mono">#${esc(r.target_id)}</span>` : ''}` },
      { label: 'Reason', render: (r) => esc(r.reason || '—') },
    ],
    onRow: (r) => drawer.open(`Audit entry #${r.id}`, async (body) => {
      body.innerHTML = `<div class="panel"><h3>Entry</h3>${kv([
        ['When', esc(fmtDate(r.created_at))],
        ['Admin', `<span class="mono">${esc(r.admin_phone)}</span> (user #${esc(r.admin_user_id ?? '—')})`],
        ['Action', badge(r.action, 'rose')],
        ['Target', `${esc(r.target_type)} #${esc(r.target_id ?? '—')}`],
        ['Reason', esc(r.reason || '—')],
      ])}</div><div class="panel"><h3>Metadata</h3><pre class="mono" style="white-space:pre-wrap;margin:0">${esc(JSON.stringify(r.metadata, null, 2))}</pre></div>
      ${r.target_type === 'user' ? `<button class="btn-ghost btn-sm" data-u>Open user #${esc(r.target_id)}</button>` : ''}
      ${r.target_type === 'listener' ? `<button class="btn-ghost btn-sm" data-l>Open creator #${esc(r.target_id)}</button>` : ''}
      ${r.target_type === 'report' ? `<button class="btn-ghost btn-sm" data-rp>Open report #${esc(r.target_id)}</button>` : ''}`;
      body.querySelector('[data-u]')?.addEventListener('click', () => openUser(r.target_id));
      body.querySelector('[data-l]')?.addEventListener('click', () => openListener(r.target_id));
      body.querySelector('[data-rp]')?.addEventListener('click', () => openReport(r.target_id));
    }),
  });
});


/* ---------- Operations: shared openers ---------- */

const LEDGER_REASONS = [['topup', 'Top-up'], ['call_debit', 'Call charge'], ['refund', 'Refund'], ['bonus', 'Bonus'], ['admin_adjustment', 'Admin adjustment']];
const reasonBadge = (r) => badge(r, { topup: 'green', call_debit: 'grey', refund: 'blue', bonus: 'amber', admin_adjustment: 'rose', call_credit: 'green', payout: 'amber' }[r] || 'grey');

function openWallet(userId) {
  // The wallet view picks its target up from here when it renders.
  window.__walletTarget = String(userId);
  if (location.hash === '#/wallet') route();
  else go('wallet');
}

function openCall(id) {
  drawer.open(`Call #${id}`, async (body) => {
    const c = await api(`/admin/calls/${id}`);
    body.innerHTML = `
      <div class="panel"><h3>Call (read-only)</h3>${kv([
        ['Type / status', `${badge(c.type)} ${badge(c.status)}`],
        ['Caller', `<a href="#" data-user="${c.caller_id}">${esc(c.caller_name || '—')} #${c.caller_id}</a> <span class="sub mono">${esc(c.caller_phone)}</span>`],
        ['Listener', `<a href="#" data-listener="${c.listener_id}">${esc(c.listener_name || '—')} #${c.listener_id}</a> <span class="sub mono">${esc(c.listener_phone)}</span>`],
        ['Created', esc(fmtDate(c.created_at))],
        ['Started / ended', `${esc(fmtDate(c.started_at))} → ${esc(fmtDate(c.ended_at))}`],
        ['Duration', duration(c.started_at, c.ended_at)],
        ['End reason', esc(c.end_reason || '—')],
        ['Rate (coins/min)', `${num(c.rate_per_minute)} · listener share ${num(c.listener_rate_per_minute)}`],
        ['Free seconds granted', num(c.free_seconds_granted)],
        ['Billed minutes', num(c.billed_minutes)],
        ['Caller spent', coins(c.coins_spent)],
        ['Listener earned', rupees(c.listener_earned)],
      ])}</div>
      <div class="panel"><h3>Billing ticks (${c.ticks.length})</h3>${miniTable([
        { label: 'Minute', render: (t) => t.minute_index },
        { label: 'Coins debited', num: true, render: (t) => coins(t.coins_debited) },
        { label: 'Listener share', num: true, render: (t) => rupees(t.listener_share) },
        { label: 'Platform share', num: true, render: (t) => num(t.platform_share) },
        { label: 'When', render: (t) => esc(fmtDate(t.created_at)) },
      ], c.ticks, 'No billed minutes (free trial or unanswered).')}</div>
      <div class="panel"><h3>Reports from this call</h3>${miniTable([
        { label: '#', render: (r) => `<a href="#" data-report="${r.id}">${r.id}</a>` },
        { label: 'Reporter', render: (r) => esc(r.reporter_name || '—') },
        { label: 'Reason', render: (r) => esc(r.reason) },
        { label: 'Status', render: (r) => badge(r.status) },
      ], c.reports, 'None.')}</div>`;
    body.querySelectorAll('[data-user]').forEach((a) => a.addEventListener('click', (e) => { e.preventDefault(); openUser(a.dataset.user); }));
    body.querySelectorAll('[data-listener]').forEach((a) => a.addEventListener('click', (e) => { e.preventDefault(); openListener(a.dataset.listener); }));
    body.querySelectorAll('[data-report]').forEach((a) => a.addEventListener('click', (e) => { e.preventDefault(); openReport(a.dataset.report); }));
  });
}

function postPreview(p, big = false) {
  if (!p.mediaUrl) return `<div class="ph" style="${big ? 'height:240px' : 'width:64px;height:64px'};border-radius:8px;display:grid;place-items:center;color:var(--text-faint);font-size:11px;border:1px solid var(--border)">no media</div>`;
  if (p.media_type === 'video') {
    return `<video src="${esc(p.mediaUrl)}" ${big ? 'controls style="max-width:100%;max-height:420px;border-radius:10px"' : 'muted preload="metadata" class="thumb" style="width:64px;height:64px"'}></video>`;
  }
  return `<img src="${esc(p.mediaUrl)}" alt="" ${big ? 'style="max-width:100%;max-height:420px;border-radius:10px;display:block"' : 'class="thumb" style="width:64px;height:64px"'} loading="lazy">`;
}

/* ---------- Content ---------- */

view('content', 'Content / Posts', 'Activity', (el) => {
  el.innerHTML = head('Content / Posts', 'Feed posts. Removing hides a post but keeps its media so it can be restored; posts their author deleted cannot be restored. Delete permanently (in a post) erases the post and its stored file for good. Every action needs a reason and is audit-logged.') + '<div id="t"></div>';
  const table = dataTable(el.querySelector('#t'), {
    endpoint: '/admin/posts',
    search: 'Caption, author, phone or #id…',
    sort: 'created',
    dateRange: true,
    filters: [
      { key: 'status', label: 'Status', options: [['active', 'Live'], ['removed', 'Removed']] },
      { key: 'type', label: 'Type', options: [['image', 'Image'], ['video', 'Video']] },
    ],
    columns: [
      { label: 'Preview', render: (p) => postPreview(p) },
      { label: '#', render: (p) => p.id },
      { label: 'Author', sort: 'author', render: (p) => `<a href="#" data-author="${p.author_id}">${esc(p.author_name || '—')}</a> ${p.author_status !== 'active' ? badge(p.author_status) : ''}<span class="sub mono">${esc(p.author_phone)}</span>` },
      { label: 'Type', render: (p) => badge(p.media_type) },
      { label: 'Caption', render: (p) => `<span style="display:inline-block;max-width:280px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(p.caption || '—')}</span>` },
      { label: 'Author reports', sort: 'reports', num: true, render: (p) => num(p.author_reports) },
      { label: 'Status', render: (p) => (p.status === 'removed' ? `${badge('removed')}<span class="sub">${p.removed_by_admin ? 'by admin' : 'by author'}</span>` : badge('active')) },
      { label: 'Posted', sort: 'created', render: (p) => when(p.created_at) },
      { label: 'Actions', pin: true, render: (p) => `<button class="btn-danger btn-sm" data-post-del="${p.id}" title="Permanently delete post #${p.id} and its file">Delete</button>` },
    ],
    onRow: (p) => openPost(p, () => table.reload()),
    afterLoad: (rows, tbody) => {
      tbody.querySelectorAll('[data-post-del]').forEach((b) => b.addEventListener('click', async (e) => {
        e.stopPropagation();
        if (await deleteUpload('post', b.dataset.postDel)) table.reload();
      }));
      tbody.querySelectorAll('[data-author]').forEach((a) => a.addEventListener('click', (e) => { e.preventDefault(); openUser(a.dataset.author); }));
    },
  });
});

function openPost(p, onChange) {
  drawer.open(`Post #${p.id}`, async (body) => {
    body.innerHTML = `
      <div class="drawer-actions">
        ${p.status === 'active' ? '<button class="btn-danger btn-sm" data-act="remove">Remove post</button>' : ''}
        ${p.restorable ? '<button class="btn-ok btn-sm" data-act="restore">Restore post</button>' : ''}
        <button class="btn-danger btn-sm" data-act="purge">Delete permanently</button>
        <button class="btn-ghost btn-sm" data-act="author">Open author</button>
      </div>
      <div class="panel">${postPreview(p, true)}</div>
      <div class="panel"><h3>Post</h3>${kv([
        ['Status', badge(p.status)],
        ['Type', badge(p.media_type)],
        ['Caption', esc(p.caption || '—')],
        ['Author', `${esc(p.author_name || '—')} #${p.author_id} <span class="sub mono">${esc(p.author_phone)}</span>`],
        ['Reports against author', num(p.author_reports)],
        ['Posted', esc(fmtDate(p.created_at))],
        p.status === 'removed' ? ['Removed', p.removed_by_admin ? `${esc(fmtDate(p.removed_at))} by <span class="mono">${esc(p.removed_by_phone || '—')}</span>` : 'deleted by the author'] : null,
        p.removal_reason ? ['Removal reason', esc(p.removal_reason)] : null,
      ])}</div>`;
    const act = (action) => async () => {
      const done = await dialog({
        title: action === 'remove' ? `Remove post #${p.id}?` : `Restore post #${p.id}?`,
        message: action === 'remove' ? 'It disappears from the feed immediately. Its media is kept so it can be restored.' : 'It returns to the feed.',
        fields: [{ name: 'reason', label: 'Reason', type: 'textarea', required: true }],
        confirmLabel: action === 'remove' ? 'Remove' : 'Restore',
        danger: action === 'remove',
        onSubmit: (v) => api(`/admin/posts/${p.id}`, { method: 'POST', body: { action, reason: v.reason } }),
      });
      if (done) { toast(action === 'remove' ? 'Post removed' : 'Post restored'); drawer.close(); onChange?.(); }
    };
    body.querySelector('[data-act=remove]')?.addEventListener('click', act('remove'));
    body.querySelector('[data-act=restore]')?.addEventListener('click', act('restore'));
    body.querySelector('[data-act=purge]').addEventListener('click', async () => {
      if (await deleteUpload('post', p.id)) { drawer.close(); onChange?.(); }
    });
    body.querySelector('[data-act=author]').addEventListener('click', () => openUser(p.author_id));
  });
}

/* ---------- Calls ---------- */

view('calls', 'Calls', 'Activity', (el) => {
  el.innerHTML = head('Calls', 'Read-only call and billing history. Nothing here edits historical billing.') + '<div id="t"></div>';
  dataTable(el.querySelector('#t'), {
    endpoint: '/admin/calls',
    search: 'Caller/listener name, phone or call #…',
    sort: 'created',
    dateRange: true,
    filters: [
      { key: 'type', label: 'Type', options: [['audio', 'Audio'], ['video', 'Video']] },
      { key: 'status', label: 'Status', options: [['ended', 'Ended'], ['active', 'Live'], ['ringing', 'Ringing'], ['failed', 'Failed']] },
      { key: 'endReason', label: 'End reason', options: async () => (await api('/admin/calls/meta')).endReasons.map((r) => [r, r]) },
    ],
    columns: [
      { label: '#', render: (c) => c.id },
      { label: 'Caller', render: (c) => `${esc(c.caller_name || '—')}<span class="sub mono">${esc(c.caller_phone)}</span>` },
      { label: 'Listener', render: (c) => `${esc(c.listener_name || '—')}<span class="sub mono">${esc(c.listener_phone)}</span>` },
      { label: 'Type', render: (c) => badge(c.type) },
      { label: 'Started', sort: 'created', render: (c) => `<span title="${esc(fmtDate(c.started_at || c.created_at))}">${esc(fmtDate(c.started_at || c.created_at))}</span>` },
      { label: 'Duration', sort: 'duration', num: true, render: (c) => duration(c.started_at, c.ended_at) },
      { label: 'Billed min', sort: 'minutes', num: true, render: (c) => num(c.billed_minutes) },
      { label: 'Caller spent', sort: 'coins', num: true, render: (c) => coins(c.coins_spent) },
      { label: 'Listener earned', sort: 'earned', num: true, render: (c) => rupees(c.listener_earned) },
      { label: 'End reason', render: (c) => esc(c.end_reason || '—') },
      { label: 'Status', render: (c) => badge(c.status === 'active' ? 'live' : c.status) },
    ],
    onRow: (c) => openCall(c.id),
  });
});

/* ---------- Wallet / Ledger ---------- */

view('wallet', 'Wallet / Ledger', 'Money', (el) => {
  el.innerHTML = head('Wallet / Ledger', 'Look up a user’s coin wallet and complete ledger. Adjustments append a new ledger row (never edit old ones) and are audit-logged.') + `
    <div class="panel" style="display:flex;gap:8px;align-items:end;flex-wrap:wrap">
      <div style="flex:1;min-width:240px"><label for="wq">Find user</label><input id="wq" type="search" placeholder="Name, phone or #id…"></div>
      <div id="wmatches" style="flex-basis:100%"></div>
    </div>
    <div id="wbody">${empty('₹', 'Search for a user to see their wallet.')}</div>`;

  const matches = el.querySelector('#wmatches');
  let t;
  el.querySelector('#wq').addEventListener('input', (e) => {
    clearTimeout(t);
    const q = e.target.value.trim();
    t = setTimeout(async () => {
      if (!q) { matches.innerHTML = ''; return; }
      const res = await api(`/admin/users${qs({ q, pageSize: 8 })}`);
      matches.innerHTML = res.items.length
        ? res.items.map((u) => `<button class="btn-ghost btn-sm" data-pick="${u.id}" style="margin:2px">${esc(u.name || '—')} · <span class="mono">${esc(u.phone)}</span> · #${u.id}</button>`).join('')
        : '<span class="sub">No matching users.</span>';
      matches.querySelectorAll('[data-pick]').forEach((b) => b.addEventListener('click', () => load(b.dataset.pick)));
    }, 300);
  });

  async function load(userId) {
    matches.innerHTML = '';
    const box = el.querySelector('#wbody');
    box.innerHTML = '<div class="empty">Loading…</div>';
    try {
      const w = await api(`/admin/wallet/${userId}`);
      box.innerHTML = `
        <div class="stat-grid">
          <div class="stat"><div class="stat-label">User</div><div class="stat-value" style="font-size:16px"><a href="#" data-user="${w.user.id}">${esc(w.user.name || '—')} #${w.user.id}</a></div><span class="sub mono">${esc(w.user.phone)}</span></div>
          <div class="stat"><div class="stat-label">Coin balance</div><div class="stat-value money">${num(w.coinBalance)}</div></div>
          <div class="stat ${w.balanced ? '' : 'attn'}"><div class="stat-label">Ledger check</div><div class="stat-value" style="font-size:15px">${w.balanced ? badge('balanced', 'green') : badge(`mismatch (${num(w.ledgerTotal)})`, 'red')}</div></div>
          ${w.byReason.map((r) => `<div class="stat"><div class="stat-label">${esc(r.reason.replace(/_/g, ' '))} (${r.entries})</div><div class="stat-value" style="font-size:17px">${signed(r.total)}</div></div>`).join('')}
          ${w.listener ? `<div class="stat"><div class="stat-label">Listener earnings</div><div class="stat-value money" style="font-size:17px">₹${num(w.listener.earningsBalance)}</div><span class="sub">lifetime ₹${num(w.listener.lifetimeEarnings)}</span></div>` : ''}
        </div>
        <div class="view-head" style="margin-top:18px"><div class="section-title" style="margin:0">Coin ledger</div>
          <div class="view-actions">${w.user.status !== 'deleted' ? '<button class="btn-primary inline" data-adjust>Adjust balance</button>' : ''}</div></div>
        <div id="lt"></div>
        ${w.listener ? '<div class="section-title">Listener earnings ledger</div><div id="et"></div>' : ''}`;
      box.querySelector('[data-user]').addEventListener('click', (e) => { e.preventDefault(); openUser(w.user.id); });
      const ledger = dataTable(box.querySelector('#lt'), {
        endpoint: `/admin/ledger/${userId}`,
        search: 'Reference or entry #…',
        sort: 'created',
        dateRange: true,
        pageSize: 10,
        filters: [{ key: 'reason', label: 'Type', options: LEDGER_REASONS }],
        columns: [
          { label: '#', render: (r) => r.id },
          { label: 'When', sort: 'created', render: (r) => esc(fmtDate(r.created_at)) },
          { label: 'Type', render: (r) => reasonBadge(r.reason) },
          { label: 'Change', sort: 'delta', num: true, render: (r) => signed(r.delta) },
          { label: 'Balance after', num: true, render: (r) => coins(r.balance_after) },
          { label: 'Reference', render: (r) => refLink(r.reason, r.ref_id) },
        ],
        afterLoad: (rows, tbody) => wireRefs(tbody),
      });
      if (w.listener) {
        dataTable(box.querySelector('#et'), {
          endpoint: `/admin/earnings/${userId}`,
          search: false,
          sort: 'created',
          dateRange: true,
          pageSize: 10,
          filters: [{ key: 'reason', label: 'Type', options: [['call_credit', 'Call credit'], ['payout', 'Payout']] }],
          columns: [
            { label: '#', render: (r) => r.id },
            { label: 'When', sort: 'created', render: (r) => esc(fmtDate(r.created_at)) },
            { label: 'Type', render: (r) => reasonBadge(r.reason) },
            { label: 'Change', sort: 'delta', num: true, render: (r) => signed(r.delta) },
            { label: 'Balance after', num: true, render: (r) => rupees(r.balance_after) },
            { label: 'Reference', render: (r) => refLink(r.reason, r.ref_id) },
          ],
          afterLoad: (rows, tbody) => wireRefs(tbody),
        });
      }
      box.querySelector('[data-adjust]')?.addEventListener('click', async () => {
        const res = await dialog({
          title: `Adjust ${w.user.name || 'user'}'s coins`,
          message: `Current balance: <b>${num(w.coinBalance)}</b> coins. Use a negative number to deduct. This appends a new ledger entry and is audit-logged; it never edits existing entries.`,
          fields: [
            { name: 'amount', label: 'Amount (coins, + or −)', type: 'number', required: true, placeholder: 'e.g. 50 or -20' },
            { name: 'reason', label: 'Reason (min 5 characters)', type: 'textarea', required: true },
          ],
          confirmLabel: 'Apply adjustment',
          onSubmit: (v) => {
            const amount = Number(v.amount);
            if (!Number.isInteger(amount) || amount === 0) throw new Error('Enter a whole, non-zero number of coins.');
            return api(`/admin/wallet/${userId}/adjust`, { method: 'POST', body: { amount, reason: v.reason } });
          },
        });
        if (res) { toast(`Adjusted: new balance ${num(res.balanceAfter)}`); load(userId); }
      });
      void ledger;
    } catch (err) {
      box.innerHTML = empty('!', err.message);
    }
  }

  if (window.__walletTarget) { const id = window.__walletTarget; window.__walletTarget = null; load(id); }
});

function refLink(reason, ref) {
  if (!ref) return '—';
  if (reason === 'call_debit' || reason === 'call_credit' || reason === 'refund') {
    const id = String(ref).replace(/\D/g, '');
    return id ? `<a href="#" data-call="${id}" class="mono">call #${id}</a>` : `<span class="mono">${esc(ref)}</span>`;
  }
  if (reason === 'admin_adjustment') return `<span class="mono">${esc(ref)}</span> ${badge('audited', 'rose')}`;
  if (reason === 'payout') return `<span class="mono">payout #${esc(ref)}</span>`;
  return `<span class="mono">${esc(ref)}</span>`;
}
function wireRefs(root) {
  root.querySelectorAll('[data-call]').forEach((a) => a.addEventListener('click', (e) => { e.preventDefault(); openCall(a.dataset.call); }));
}

/* ---------- Payouts ---------- */

view('payouts', 'Payouts', 'Money', (el) => {
  el.innerHTML = head('Payouts', 'No payout provider is integrated: "paid" means approved and debited from earnings by the worker — no money is transferred by Moco. After paying outside Moco, record the transfer reference.') + '<div id="t"></div>';
  const table = dataTable(el.querySelector('#t'), {
    endpoint: '/admin/payouts',
    search: 'Creator, phone, UPI or reference…',
    initial: { status: 'requested' },
    dateRange: true,
    filters: [{ key: 'status', label: 'Status', options: [['requested', 'Pending'], ['approved', 'Approved'], ['paid', 'Paid (recorded)'], ['rejected', 'Rejected'], ['all', 'Everything']] }],
    columns: [
      { label: '#', render: (p) => p.id },
      { label: 'Creator', render: (p) => `<a href="#" data-l="${p.listener_id}">${esc(p.display_name || '—')}</a><span class="sub mono">${esc(p.phone)}</span>` },
      { label: 'Amount', sort: 'amount', num: true, render: (p) => rupees(p.amount) },
      { label: 'Earnings bal.', num: true, render: (p) => rupees(p.earnings_balance) },
      { label: 'UPI', render: (p) => `<span class="mono">${esc(p.upi_id || '—')}</span>` },
      { label: 'Requested', sort: 'created', render: (p) => when(p.created_at) },
      { label: 'Status', render: (p) => `${badge(p.status)}${p.status === 'paid' ? '<span class="sub">recorded · not transferred by Moco</span>' : ''}` },
      { label: 'Reviewed', render: (p) => (p.reviewed_at ? `${when(p.reviewed_at)}<span class="sub mono">${esc(p.reviewed_by_phone || '')}</span>` : '—') },
      { label: 'Reference / note', sort: 'processed', render: (p) => `${p.upi_ref ? `<span class="mono">${esc(p.upi_ref)}</span>` : '—'}${p.note ? `<span class="sub">${esc(p.note)}</span>` : ''}` },
      { label: '', render: (p) => (p.status === 'requested'
        ? `<button class="btn-ok btn-sm" data-ap="${p.id}">Approve</button> <button class="btn-danger btn-sm" data-rj="${p.id}">Reject</button>`
        : p.status === 'paid' && !p.upi_ref ? `<button class="btn-ghost btn-sm" data-ref="${p.id}">Record reference</button>` : '') },
    ],
    afterLoad: (rows, tbody) => {
      const decide = (id, approve) => async () => {
        const ok = await dialog({
          title: approve ? `Approve payout #${id}?` : `Reject payout #${id}?`,
          message: approve ? 'The worker will debit the creator’s earnings and mark it paid. It does NOT send money — pay outside Moco and record the reference.' : 'The creator is notified with your reason.',
          fields: [{ name: 'note', label: approve ? 'Note' : 'Reason (sent to the creator)', type: 'textarea', required: !approve }],
          confirmLabel: approve ? 'Approve' : 'Reject',
          danger: !approve,
          onSubmit: (v) => api(`/admin/payouts/${id}`, { method: 'POST', body: { approve, note: v.note || undefined } }),
        });
        if (ok) { toast('Payout updated'); refreshCounts(); table.reload(); }
      };
      tbody.querySelectorAll('[data-ap]').forEach((b) => b.addEventListener('click', decide(b.dataset.ap, true)));
      tbody.querySelectorAll('[data-rj]').forEach((b) => b.addEventListener('click', decide(b.dataset.rj, false)));
      tbody.querySelectorAll('[data-ref]').forEach((b) => b.addEventListener('click', async () => {
        const ok = await dialog({
          title: `Record transfer reference for payout #${b.dataset.ref}`,
          message: 'Documents a transfer you made outside Moco (e.g. a UPI transaction id). It does not move money.',
          fields: [{ name: 'upiRef', label: 'Transfer reference', required: true }, { name: 'note', label: 'Note', type: 'textarea' }],
          confirmLabel: 'Save reference',
          onSubmit: (v) => api(`/admin/payouts/${b.dataset.ref}/reference`, { method: 'POST', body: { upiRef: v.upiRef, note: v.note || undefined } }),
        });
        if (ok) { toast('Reference recorded'); table.reload(); }
      }));
      tbody.querySelectorAll('[data-l]').forEach((a) => a.addEventListener('click', (e) => { e.preventDefault(); openListener(a.dataset.l); }));
    },
  });
}, 'payouts');

/* ---------- System ---------- */

view('system', 'System / Reconcile', 'System', (el) => {
  el.innerHTML = head('System', 'Live dependency health and money reconciliation. No hosts, keys or credentials are ever shown.', '<button class="btn-ghost btn-sm" data-r>Re-check</button>') +
    '<div class="section-title">Health</div><div class="health-grid" id="hl"><div class="empty">Checking…</div></div>' +
    '<div class="section-title">Queues</div><div id="qs"></div>' +
    '<div class="section-title">Coin wallets ↔ coin ledger</div><div id="rec"></div>' +
    '<div class="section-title">Listener earnings ↔ earnings ledger</div><div id="rec2"></div>';

  const card = (title, ok, detail) => `<div class="health"><div class="h-title">${esc(title)} ${badge(ok ? 'ok' : 'down')}</div><div class="h-detail">${detail}</div></div>`;

  async function load() {
    try {
      const h = await api('/admin/system/health');
      const db = h.database;
      el.querySelector('#hl').innerHTML = [
        card('API', h.api.ok, `up ${Math.floor(h.api.uptimeSeconds / 60)} min · ${esc(h.api.node)} · ${esc(h.api.env)}`),
        card('Database', db.ok, db.ok ? `${db.latencyMs} ms · migrations ${db.migrations.applied}/${db.migrations.files}${db.migrations.pending.length ? ` · ${badge('pending: ' + db.migrations.pending.join(', '), 'amber')}` : ''} · pool ${db.pool.total} (${db.pool.idle} idle)` : esc(db.error)),
        card('Redis', h.redis.ok, h.redis.ok ? `${h.redis.latencyMs} ms` : esc(h.redis.error)),
        card('Storage', h.storage.ok, h.storage.ok ? `${h.storage.latencyMs} ms · ${h.storage.buckets.map((b) => `${esc(b.name)} ${b.private ? badge('private', 'green') : badge('PUBLIC', 'red')}`).join(' ')}` : esc(h.storage.error || 'not configured')),
        card('Tick worker (billing)', h.tickWorker.ok, h.tickWorker.ok ? `last heartbeat ${h.tickWorker.ageSeconds}s ago` : esc(h.tickWorker.error)),
      ].join('');
      el.querySelector('#qs').innerHTML = h.queues.ok
        ? `<div class="panel">${miniTable([
            { label: 'Queue', render: (r) => esc(r.name) },
            { label: 'Waiting', num: true, render: (r) => num(r.waiting) },
            { label: 'Active', num: true, render: (r) => num(r.active) },
            { label: 'Delayed', num: true, render: (r) => num(r.delayed) },
            { label: 'Failed', num: true, render: (r) => (r.failed ? `<span class="neg">${num(r.failed)}</span>` : '0') },
          ], ['tick', 'payout', 'notification'].map((n) => ({ name: n, ...h.queues[n] })))}</div>`
        : `<div class="panel">${badge('down')} ${esc(h.queues.error)}</div>`;
    } catch (err) {
      el.querySelector('#hl').innerHTML = empty('!', err.message);
    }
    const rec = async (sel, path, label) => {
      const box = el.querySelector(sel);
      try {
        const r = await api(path);
        box.innerHTML = r.balanced
          ? `<div class="panel">${badge('ok')} Every ${label} matches its ledger.</div>`
          : `<div class="panel">${badge('mismatch', 'red')} ${r.discrepancies.length} ${label}(s) disagree with their ledger.${miniTable([
              { label: 'User', render: (d) => `<a href="#" data-user="${d.user_id}">#${d.user_id}</a>` },
              { label: 'Balance', num: true, render: (d) => num(d.coin_balance ?? d.earnings_balance) },
              { label: 'Ledger sum', num: true, render: (d) => num(d.ledger_total) },
            ], r.discrepancies)}</div>`;
        box.querySelectorAll('[data-user]').forEach((a) => a.addEventListener('click', (e) => { e.preventDefault(); openUser(a.dataset.user); }));
      } catch (err) {
        box.innerHTML = empty('!', err.message);
      }
    };
    rec('#rec', '/admin/reconcile', 'wallet');
    rec('#rec2', '/admin/reconcile/earnings', 'earnings balance');
  }
  el.querySelector('[data-r]').addEventListener('click', load);
  load();
});

/* =====================================================================
 * Boot
 * ===================================================================== */

(async () => {
  if (!token) return;
  try {
    await api('/admin/me');
    enterConsole();
  } catch {
    signOut();
  }
})();
