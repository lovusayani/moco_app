'use strict';

/**
 * Moco admin console.
 *
 * Served from the API origin, so it talks to /api directly with no CORS setup.
 * The token lives in localStorage: this is an internal tool on an operator's
 * own machine, and the server re-checks the admin allow-list on every request,
 * so a stolen token grants nothing a stolen phone would not.
 */

const API = '/api';
const TOKEN_KEY = 'moco_admin_token';
const PHONE_KEY = 'moco_admin_phone';

let token = localStorage.getItem(TOKEN_KEY);
let pendingPhone = '';

/* ---------- HTTP ---------- */

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
  const data = text ? JSON.parse(text) : null;

  if (!response.ok) {
    // A 401 means the token is gone or invalid; drop it and show the login
    // rather than leaving the operator staring at a half-broken console.
    if (response.status === 401) signOut();
    const err = new Error(data?.error?.message || `Request failed (${response.status})`);
    err.code = data?.error?.code;
    err.status = response.status;
    throw err;
  }

  return data;
}

/* ---------- Formatting ---------- */

const esc = (value) =>
  String(value ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );

const num = (value) => Number(value ?? 0).toLocaleString('en-IN');
const coins = (value) => `${num(value)}`;
const rupees = (value) => `₹${num(value)}`;

function ago(timestamp) {
  if (!timestamp) return '—';
  const seconds = Math.floor((Date.now() - new Date(timestamp)) / 1000);
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}

function emptyState(mark, message) {
  return `<div class="empty"><div class="empty-mark">${mark}</div>${esc(message)}</div>`;
}

let toastTimer;
function toast(message, ok = true) {
  document.querySelector('.toast')?.remove();
  const el = document.createElement('div');
  el.className = `toast${ok ? '' : ' bad'}`;
  el.textContent = message;
  document.body.appendChild(el);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.remove(), 3200);
}

/* ---------- Auth ---------- */

const loginEl = document.getElementById('login');
const appEl = document.getElementById('app');
const errorEl = document.getElementById('login-error');

function showLoginError(message) {
  errorEl.textContent = message;
  errorEl.hidden = false;
}

document.getElementById('phone-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  errorEl.hidden = true;
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

document.getElementById('code-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  errorEl.hidden = true;

  try {
    const result = await api('/auth/otp/verify', {
      method: 'POST',
      body: { phone: pendingPhone, code: document.getElementById('code').value.trim() },
    });

    token = result.token;
    localStorage.setItem(TOKEN_KEY, token);
    localStorage.setItem(PHONE_KEY, pendingPhone);

    // Confirm the account is actually on the admin allow-list before showing
    // the console, so a non-admin gets a clear message instead of empty tables.
    await api('/admin/stats');
    enterConsole();
  } catch (err) {
    if (err.status === 403) {
      showLoginError('That number is signed in, but it is not an admin. Add it to ADMIN_PHONES.');
      token = null;
      localStorage.removeItem(TOKEN_KEY);
    } else {
      showLoginError(err.message);
    }
  }
});

document.getElementById('back-btn').addEventListener('click', () => {
  document.getElementById('code-form').hidden = true;
  document.getElementById('phone-form').hidden = false;
  errorEl.hidden = true;
});

function signOut() {
  token = null;
  localStorage.removeItem(TOKEN_KEY);
  appEl.hidden = true;
  loginEl.hidden = false;
  document.getElementById('code-form').hidden = true;
  document.getElementById('phone-form').hidden = false;
}

document.getElementById('logout-btn').addEventListener('click', signOut);

function enterConsole() {
  loginEl.hidden = true;
  appEl.hidden = false;
  document.getElementById('admin-phone').textContent = localStorage.getItem(PHONE_KEY) || '';
  loadView('overview');
  refreshCounts();
}

/* ---------- Views ---------- */

const VIEWS = ['overview', 'kyc', 'payouts', 'reports', 'reconcile'];
let currentView = 'overview';

document.querySelectorAll('.nav-item').forEach((button) => {
  button.addEventListener('click', () => {
    document.querySelectorAll('.nav-item').forEach((b) => b.classList.remove('active'));
    button.classList.add('active');
    loadView(button.dataset.view);
  });
});

document.querySelectorAll('[data-refresh]').forEach((button) => {
  button.addEventListener('click', () => loadView(button.dataset.refresh));
});

function loadView(view) {
  currentView = view;
  VIEWS.forEach((name) => {
    document.getElementById(`view-${name}`).hidden = name !== view;
  });

  const loaders = {
    overview: loadOverview,
    kyc: loadKyc,
    payouts: loadPayouts,
    reports: loadReports,
    reconcile: loadReconcile,
  };

  loaders[view]().catch((err) => toast(err.message, false));
}

/** Keeps the sidebar badges honest without reloading the whole view. */
async function refreshCounts() {
  try {
    const stats = await api('/admin/stats');
    setCount('count-kyc', stats.pending_kyc);
    setCount('count-payouts', stats.pending_payouts);
    setCount('count-reports', stats.open_reports);
  } catch {
    /* Badges are cosmetic; a failure here must not disrupt the console. */
  }
}

function setCount(id, value) {
  const el = document.getElementById(id);
  el.textContent = value > 0 ? value : '';
  el.dataset.count = value || 0;
}

/* ---------- Overview ---------- */

async function loadOverview() {
  const stats = await api('/admin/stats');

  const cards = [
    { label: 'Live calls', value: num(stats.live_calls), cls: stats.live_calls > 0 ? 'live' : '' },
    { label: 'Listeners online', value: num(stats.online_listeners), note: `${num(stats.approved_listeners)} approved` },
    { label: 'Active users', value: num(stats.active_users) },
    { label: 'Calls today', value: num(stats.calls_today) },
    { label: 'Coins spent today', value: coins(stats.coins_spent_today) },
    { label: 'Platform revenue today', value: rupees(stats.platform_revenue_today), cls: 'accent' },
    { label: 'Coins purchased today', value: coins(stats.coins_purchased_today) },
    { label: 'Pending payouts', value: num(stats.pending_payouts) },
    { label: 'Open reports', value: num(stats.open_reports) },
  ];

  document.getElementById('stat-grid').innerHTML = cards
    .map(
      (card) => `
      <div class="stat">
        <div class="stat-label">${esc(card.label)}</div>
        <div class="stat-value ${card.cls || ''}">${card.value}</div>
        ${card.note ? `<div class="stat-note">${esc(card.note)}</div>` : ''}
      </div>`,
    )
    .join('');

  setCount('count-payouts', stats.pending_payouts);
  setCount('count-reports', stats.open_reports);
  if (stats.pending_kyc !== undefined) setCount('count-kyc', stats.pending_kyc);
}

/* ---------- KYC ---------- */

async function loadKyc() {
  const { pending } = await api('/admin/kyc');
  setCount('count-kyc', pending.length);

  const target = document.getElementById('kyc-table');

  if (pending.length === 0) {
    target.innerHTML = emptyState('✓', 'No submissions waiting for review.');
    return;
  }

  target.innerHTML = `
    <table>
      <thead>
        <tr><th>Listener</th><th>Legal name</th><th>UPI</th><th>Document</th><th>Submitted</th><th></th></tr>
      </thead>
      <tbody>
        ${pending
          .map(
            (row) => `
          <tr data-row="${row.user_id}">
            <td>
              <div class="cell-name">${esc(row.display_name || '—')}</div>
              <div class="cell-sub mono">${esc(row.phone)}</div>
            </td>
            <td>${esc(row.kyc_name || '—')}</td>
            <td class="mono">${esc(row.upi_id || '—')}</td>
            <td>${row.kyc_doc_url ? `<a href="${esc(row.kyc_doc_url)}" target="_blank" rel="noopener">View</a>` : '—'}</td>
            <td class="cell-sub">${ago(row.updated_at)}</td>
            <td>
              <div class="actions">
                <button class="btn-approve btn-sm" data-kyc-approve="${row.user_id}">Approve</button>
                <button class="btn-reject btn-sm" data-kyc-reject="${row.user_id}">Reject</button>
              </div>
            </td>
          </tr>`,
          )
          .join('')}
      </tbody>
    </table>`;
}

/* ---------- Payouts ---------- */

async function loadPayouts() {
  const { pending } = await api('/admin/payouts');
  setCount('count-payouts', pending.length);

  const target = document.getElementById('payouts-table');

  if (pending.length === 0) {
    target.innerHTML = emptyState('✓', 'No withdrawal requests waiting.');
    return;
  }

  target.innerHTML = `
    <table>
      <thead>
        <tr><th>Listener</th><th>UPI</th><th class="num">Amount</th><th class="num">Earnings balance</th><th>Requested</th><th></th></tr>
      </thead>
      <tbody>
        ${pending
          .map(
            (row) => `
          <tr data-row="${row.id}">
            <td>
              <div class="cell-name">${esc(row.display_name || '—')}</div>
              <div class="cell-sub mono">${esc(row.phone)}</div>
            </td>
            <td class="mono">${esc(row.upi_id || '—')}</td>
            <td class="num"><strong>${rupees(row.amount)}</strong></td>
            <td class="num">${rupees(row.earnings_balance)}</td>
            <td class="cell-sub">${ago(row.created_at)}</td>
            <td>
              <div class="actions">
                <button class="btn-approve btn-sm" data-payout-approve="${row.id}">Approve</button>
                <button class="btn-reject btn-sm" data-payout-reject="${row.id}">Reject</button>
              </div>
            </td>
          </tr>`,
          )
          .join('')}
      </tbody>
    </table>`;
}

/* ---------- Reports ---------- */

async function loadReports() {
  const { reports } = await api('/admin/reports');
  setCount('count-reports', reports.length);

  const target = document.getElementById('reports-table');

  if (reports.length === 0) {
    target.innerHTML = emptyState('✓', 'No open reports.');
    return;
  }

  target.innerHTML = `
    <table>
      <thead>
        <tr><th>Reported</th><th>Reason</th><th>Details</th><th>By</th><th>Filed</th><th></th></tr>
      </thead>
      <tbody>
        ${reports
          .map(
            (row) => `
          <tr data-row="${row.id}">
            <td>
              <div class="cell-name">${esc(row.reported_name || '—')}</div>
              ${
                row.total_reports > 1
                  ? `<span class="pill pill-bad">${row.total_reports} reports</span>`
                  : '<span class="pill pill-mute">1 report</span>'
              }
            </td>
            <td><span class="pill pill-warn">${esc(String(row.reason).replace(/_/g, ' '))}</span></td>
            <td class="cell-sub">${esc(row.details || '—')}</td>
            <td class="cell-sub">${esc(row.reporter_name || '—')}</td>
            <td class="cell-sub">${ago(row.created_at)}</td>
            <td>
              <div class="actions">
                <button class="btn-ghost btn-sm" data-report-dismiss="${row.id}">Dismiss</button>
                <button class="btn-reject btn-sm" data-report-suspend="${row.id}">Suspend</button>
              </div>
            </td>
          </tr>`,
          )
          .join('')}
      </tbody>
    </table>`;
}

/* ---------- Reconcile ---------- */

async function loadReconcile() {
  const result = await api('/admin/reconcile');
  const target = document.getElementById('reconcile-body');

  if (result.balanced) {
    target.innerHTML = `
      <div class="banner banner-good">
        <strong>Balanced.</strong> Every wallet matches the sum of its ledger.
      </div>
      <p class="view-sub">Checked live against the database. This is the check that would catch coins moving without a ledger row — worth wiring to an alert in production.</p>`;
    return;
  }

  target.innerHTML = `
    <div class="banner banner-bad">
      <strong>${result.discrepancies.length} discrepancies.</strong>
      Coins moved without a matching ledger row. Investigate before processing payouts.
    </div>
    <div class="table-wrap">
      <table>
        <thead><tr><th>User</th><th class="num">Wallet balance</th><th class="num">Ledger total</th><th class="num">Difference</th></tr></thead>
        <tbody>
          ${result.discrepancies
            .map(
              (row) => `
            <tr>
              <td class="mono">#${row.user_id}</td>
              <td class="num">${coins(row.coin_balance)}</td>
              <td class="num">${coins(row.ledger_total)}</td>
              <td class="num" style="color:var(--red)">${coins(row.coin_balance - row.ledger_total)}</td>
            </tr>`,
            )
            .join('')}
        </tbody>
      </table>
    </div>`;
}

/* ---------- Actions ---------- */

/**
 * One delegated listener for every action button. Rows are re-rendered on each
 * load, so per-button listeners would leak; delegation also means a newly
 * rendered row is immediately live without rebinding.
 */
document.addEventListener('click', async (event) => {
  const button = event.target.closest('button[data-kyc-approve], button[data-kyc-reject], button[data-payout-approve], button[data-payout-reject], button[data-report-dismiss], button[data-report-suspend]');
  if (!button) return;

  const data = button.dataset;
  let request;
  let message;
  let confirmText;

  if (data.kycApprove) {
    request = () => api(`/admin/kyc/${data.kycApprove}`, { method: 'POST', body: { approve: true } });
    message = 'Listener approved';
  } else if (data.kycReject) {
    request = () => api(`/admin/kyc/${data.kycReject}`, { method: 'POST', body: { approve: false } });
    message = 'Submission rejected';
  } else if (data.payoutApprove) {
    // Approving moves real money, so it asks first.
    confirmText = 'Approve this withdrawal? This queues the payout worker, which debits the listener\'s earnings.';
    request = () => api(`/admin/payouts/${data.payoutApprove}`, { method: 'POST', body: { approve: true } });
    message = 'Payout approved and queued';
  } else if (data.payoutReject) {
    request = () => api(`/admin/payouts/${data.payoutReject}`, { method: 'POST', body: { approve: false } });
    message = 'Payout rejected';
  } else if (data.reportDismiss) {
    request = () => api(`/admin/reports/${data.reportDismiss}`, { method: 'POST', body: { action: 'dismiss' } });
    message = 'Report dismissed';
  } else if (data.reportSuspend) {
    confirmText = 'Suspend this user? They lose access immediately and are removed from discovery.';
    request = () => api(`/admin/reports/${data.reportSuspend}`, { method: 'POST', body: { action: 'suspend' } });
    message = 'User suspended';
  }

  if (confirmText && !window.confirm(confirmText)) return;

  button.disabled = true;
  try {
    await request();
    toast(message);
    loadView(currentView);
    refreshCounts();
  } catch (err) {
    toast(err.message, false);
    button.disabled = false;
  }
});

/* ---------- Boot ---------- */

(async function boot() {
  const hint = document.getElementById('login-hint');

  try {
    const config = await fetch(`${API}/config`).then((r) => r.json());
    // Outside production the OTP is fixed, which saves the operator guessing.
    if (config.devOtp) {
      hint.textContent = `Development mode — the verification code is ${config.devOtp}.`;
    }
  } catch {
    hint.textContent = 'Could not reach the API. Is the server running?';
  }

  if (!token) return;

  // A stored token still has to pass the admin check before the console opens.
  try {
    await api('/admin/stats');
    enterConsole();
  } catch {
    signOut();
  }
})();
