/* ==========================================================================
   ESP32 Power Meter — dashboard logic (vanilla JS, no framework)

   Talks to the FastAPI backend:
     GET /api/health                          -> {"status":"ok"}
     GET /api/latest                          -> newest sample + online flag
     GET /api/history?minutes=&max_points=    -> downsampled time series
     GET /api/stats?hours=24                  -> 24h energy / averages

   Polling model:
     - /api/latest  every 1 s   (tiles, pills, live chart points)
     - /api/history every 60 s  and whenever the range changes
     - /api/stats   every 60 s
   ========================================================================== */
'use strict';

/* ------------------------------ configuration ----------------------------- */

/* Backend this dashboard talks to when the browser has nothing saved yet.
   Change this one line to repoint the published dashboard; whatever you save
   in the settings panel overrides it for your browser only. Leave it as ''
   to force the settings panel open on a first visit instead. */
const DEFAULT_BASE_URL   = 'https://powermeter.dilanp.duckdns.org';

const STORAGE_KEY        = 'powermeter.baseUrl';
const LATEST_INTERVAL_MS = 1000;    // ESP32 posts every 1 s, so poll every 1 s
const SLOW_INTERVAL_MS   = 60000;   // history + stats refresh
const FETCH_TIMEOUT_MS   = 6000;    // abort hung requests so polls don't pile up
const MAX_POINTS         = 500;     // server-side downsampling cap
const LIVE_APPEND_MAX_MIN = 60;     // append live points only on short ranges

/* Per-metric display formatting. null from the PZEM renders as an em dash. */
const FMT = {
  power:     v => v.toFixed(1),
  voltage:   v => v.toFixed(1),
  current:   v => v.toFixed(3),
  frequency: v => v.toFixed(1),
  pf:        v => v.toFixed(2),
  energy:    v => v.toFixed(3),
};
const EM_DASH = '—';

/* One entry per chart. `accent` names a CSS variable so light/dark colors
   live in style.css only. Color follows the metric — it never changes. */
const CHART_DEFS = [
  { field: 'power',     canvas: 'chartPower',     accent: 'indigo', fill: true,  unit: 'W',   zero: true  },
  { field: 'voltage',   canvas: 'chartVoltage',   accent: 'cyan',   fill: false, unit: 'V',   zero: false },
  { field: 'current',   canvas: 'chartCurrent',   accent: 'indigo', fill: false, unit: 'A',   zero: true  },
  { field: 'frequency', canvas: 'chartFrequency', accent: 'cyan',   fill: false, unit: 'Hz',  zero: false },
  { field: 'pf',        canvas: 'chartPf',        accent: 'indigo', fill: false, unit: '',    zero: true, max: 1 },
  { field: 'energy',    canvas: 'chartEnergy',    accent: 'cyan',   fill: false, unit: 'kWh', zero: false },
];

/* ---------------------------------- state --------------------------------- */

/* ?? not || : a saved empty string is an explicit "unset it", and must not
   silently fall back to the default. */
let baseUrl        = normalizeBaseUrl(localStorage.getItem(STORAGE_KEY) ?? DEFAULT_BASE_URL);
let rangeMinutes   = 60;            // default range: 1h
let charts         = {};            // field -> Chart instance
let latestTimer    = null;
let slowTimer      = null;
let latestInFlight = false;

let serverReachable   = null;       // null = unknown yet
let bannerDismissed   = false;      // "don't re-show until the outage ends"
let lastUpdateAt      = null;       // Date.now() of last good /api/latest
let lastHistoryTs     = 0;          // newest ts (unix s) in the loaded history

/* --------------------------------- helpers -------------------------------- */

/** Trim whitespace and any trailing slashes: "https://x.org/" -> "https://x.org" */
function normalizeBaseUrl(url) {
  return (url || '').trim().replace(/\/+$/, '');
}

/** True when this page is https but the target URL is plain http (browsers block it). */
function isMixedContent(url) {
  return location.protocol === 'https:' && /^http:\/\//i.test(url);
}

/** Read a CSS custom property off :root (theme-aware chart colors). */
function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

/* Free ngrok tunnels answer browser requests with an HTML interstitial instead
   of the API response; this header opts out of it. Harmless on every other
   backend, which simply ignores an unknown request header. */
const FETCH_OPTS = {
  cache: 'no-store',
  headers: { 'ngrok-skip-browser-warning': 'true' },
};

/**
 * GET a JSON endpoint with a timeout.
 * Resolves { status, body } for ANY http response (404 still means the
 * server is reachable); rejects only on network failure / timeout.
 */
async function getJson(path) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    const res  = await fetch(baseUrl + path, { ...FETCH_OPTS, signal: controller.signal });
    const body = await res.json().catch(() => null);
    return { status: res.status, body };
  } finally {
    clearTimeout(timer);
  }
}

/** Format a metric value, or an em dash when the PZEM read failed (null). */
function fmtVal(field, value) {
  return (value === null || value === undefined || Number.isNaN(value))
    ? EM_DASH
    : FMT[field](value);
}

function setText(id, text) {
  document.getElementById(id).textContent = text;
}

/* --------------------------- server / device pills ------------------------- */

function setPill(id, state, label) {
  const pill = document.getElementById(id);
  pill.dataset.state = state;                       // drives the dot color
  pill.querySelector('.pill-text').textContent = label;
}

/** Called after every /api/latest attempt: flips pills + banner exactly once per change. */
function setServerReachable(ok, failedUrl) {
  if (ok) {
    if (serverReachable !== true) {
      setPill('serverPill', 'good', 'Connected');
      hideBanner();
      bannerDismissed = false;                      // re-arm the banner for the next outage
      serverReachable = true;
    }
  } else {
    if (serverReachable !== false) {
      setPill('serverPill', 'bad', 'Unreachable');
      setPill('devicePill', 'idle', 'Offline');
      // log once per outage — never a console-spam loop
      console.warn('Power meter backend unreachable:', failedUrl);
      serverReachable = false;
    }
    if (!bannerDismissed) showBanner(`Can’t reach the backend at ${failedUrl} — retrying…`);
  }
}

/* ------------------------------- error banner ------------------------------ */

function showBanner(message) {
  setText('errorBannerText', message);
  document.getElementById('errorBanner').hidden = false;
}
function hideBanner() {
  document.getElementById('errorBanner').hidden = true;
}
document.getElementById('errorBannerClose').addEventListener('click', () => {
  bannerDismissed = true;                           // stays hidden until recovery
  hideBanner();
});

/* ------------------------------ "updated Xs ago" --------------------------- */

setInterval(() => {
  if (lastUpdateAt === null) { setText('updatedAgo', 'updated ' + EM_DASH); return; }
  const s = Math.max(0, Math.round((Date.now() - lastUpdateAt) / 1000));
  let label;
  if      (s < 60)   label = `${s}s ago`;
  else if (s < 3600) label = `${Math.floor(s / 60)}m ago`;
  else               label = `${Math.floor(s / 3600)}h ago`;
  setText('updatedAgo', 'updated ' + label);
}, 1000);

/* ------------------------------- stat tiles -------------------------------- */

function renderLatest(d) {
  setText('valPower',     fmtVal('power',     d.power));
  setText('valVoltage',   fmtVal('voltage',   d.voltage));
  setText('valCurrent',   fmtVal('current',   d.current));
  setText('valFrequency', fmtVal('frequency', d.frequency));
  setText('valPf',        fmtVal('pf',        d.pf));
  setText('valEnergy',    fmtVal('energy',    d.energy));

  // device id + RSSI, tucked under the title (subtle by design)
  const rssi = (d.rssi === null || d.rssi === undefined) ? EM_DASH : `${d.rssi} dBm`;
  setText('deviceMeta', `${d.device_id} · ${rssi}`);

  // hero tile subtitle: sampling context
  const age = Math.round(d.age_s);
  setText('heroSub', d.online ? `live · sampled ${age}s ago` : `last seen ${age}s ago`);

  setPill('devicePill', d.online ? 'good' : 'bad', d.online ? 'Live' : 'Offline');
}

function renderStats(s) {
  // Every stat field is null until the window holds at least one reading.
  const stat = (v, digits) => (v === null || v === undefined) ? EM_DASH : v.toFixed(digits);
  setText('valEnergyToday', stat(s.energy_kwh, 3));
  setText('valAvgPower',    stat(s.avg_power,  1));
  setText('valPeakPower',   stat(s.max_power,  1));
}

function renderNoData() {
  ['valPower','valVoltage','valCurrent','valFrequency','valPf','valEnergy'].forEach(id => setText(id, EM_DASH));
  setText('heroSub', 'no data yet — waiting for the first sample');
  setPill('devicePill', 'idle', 'No data');
}

/* ================================== CHARTS ================================== */

/* Global Chart.js defaults (system font, honest motion) */
Chart.defaults.font.family = 'system-ui, -apple-system, "Segoe UI", sans-serif';
Chart.defaults.font.size   = 11;
if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
  Chart.defaults.animation = false;
}

/**
 * Tiny plugin: a vertical hairline that snaps to the hovered X position,
 * so readers aim at a time, not at a 2px line.
 */
const crosshairPlugin = {
  id: 'crosshair',
  afterDatasetsDraw(chart) {
    const active = chart.tooltip && chart.tooltip.getActiveElements();
    if (!active || !active.length) return;
    const x = active[0].element.x;
    const { top, bottom } = chart.chartArea;
    const ctx = chart.ctx;
    ctx.save();
    ctx.beginPath();
    ctx.moveTo(x, top);
    ctx.lineTo(x, bottom);
    ctx.lineWidth = 1;
    ctx.strokeStyle = chart.$crosshairColor || 'rgba(128,128,128,0.4)';
    ctx.stroke();
    ctx.restore();
  },
};

/** Current theme colors for one chart definition (resolved from CSS variables). */
function themeColors(def) {
  return {
    line:    cssVar(`--${def.accent}`),
    wash:    cssVar(`--${def.accent}-wash`),
    grid:    cssVar('--grid'),
    ticks:   cssVar('--text-muted'),
    tipBg:   cssVar('--tooltip-bg'),
    tipBody: cssVar('--text-primary'),
    tipTitle: cssVar('--text-secondary'),
    border:  cssVar('--border'),
  };
}

function makeChart(def) {
  const c   = themeColors(def);
  const ctx = document.getElementById(def.canvas);

  const chart = new Chart(ctx, {
    type: 'line',
    data: {
      datasets: [{
        label: def.field,
        data: [],                       // filled by /api/history
        parsing: false,                 // we supply {x: ms, y: value} directly
        borderColor: c.line,
        backgroundColor: c.wash,        // ~10% wash, only visible when fill:true
        fill: def.fill ? 'origin' : false,
        borderWidth: 2,                 // thin marks: 2px line
        borderJoinStyle: 'round',
        borderCapStyle: 'round',
        pointRadius: 0,                 // clean line; hover reveals the point
        pointHoverRadius: 5,
        pointHoverBackgroundColor: c.line,
        pointHoverBorderColor: c.tipBg, // 2px surface ring on the hover marker
        pointHoverBorderWidth: 2,
        spanGaps: false,                // null (failed PZEM read) = visible gap
      }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,       // the .chart-box height rules
      animation: false,                 // live data; redraws must not wiggle
      normalized: true,
      interaction: { mode: 'index', intersect: false }, // generous hit target
      plugins: {
        legend: { display: false },     // single series: the card title names it
        tooltip: {
          backgroundColor: c.tipBg,
          titleColor: c.tipTitle,       // label follows…
          bodyColor: c.tipBody,         // …value leads
          titleFont: { weight: 'normal', size: 11 },
          bodyFont: { weight: '600', size: 13 },
          borderColor: c.border,
          borderWidth: 1,
          padding: 10,
          cornerRadius: 10,
          displayColors: false,         // one series — no swatch needed
          callbacks: {
            label: (item) => `${fmtVal(def.field, item.parsed.y)} ${def.unit}`.trim(),
          },
        },
      },
      scales: {
        x: {
          type: 'time',                 // luxon adapter handles all formatting
          time: { tooltipFormat: 'd LLL yyyy, HH:mm:ss' },
          grid: { display: false },     // recessive chrome: y-gridlines only
          border: { color: c.grid },
          ticks: {
            color: c.ticks,
            maxRotation: 0,
            autoSkip: true,
            maxTicksLimit: def.fill ? 9 : 6,
          },
        },
        y: {
          beginAtZero: def.zero,
          suggestedMax: def.max,        // pf gets a 0..1 frame
          grace: def.zero ? 0 : '8%',   // non-zero axes breathe a little
          grid: { color: c.grid },      // solid hairlines, one step off surface
          border: { display: false },
          ticks: {
            color: c.ticks,
            maxTicksLimit: 5,
            font: { size: 11 },
          },
        },
      },
    },
    plugins: [crosshairPlugin],
  });

  chart.$crosshairColor = c.ticks;
  return chart;
}

/** Re-resolve CSS variables and restyle every chart in place (theme flipped). */
function restyleCharts() {
  for (const def of CHART_DEFS) {
    const chart = charts[def.field];
    if (!chart) continue;
    const c  = themeColors(def);
    const ds = chart.data.datasets[0];
    ds.borderColor = c.line;
    ds.backgroundColor = c.wash;
    ds.pointHoverBackgroundColor = c.line;
    ds.pointHoverBorderColor = c.tipBg;
    const o = chart.options;
    o.plugins.tooltip.backgroundColor = c.tipBg;
    o.plugins.tooltip.titleColor = c.tipTitle;
    o.plugins.tooltip.bodyColor = c.tipBody;
    o.plugins.tooltip.borderColor = c.border;
    o.scales.x.ticks.color = c.ticks;
    o.scales.x.border.color = c.grid;
    o.scales.y.ticks.color = c.ticks;
    o.scales.y.grid.color = c.grid;
    chart.$crosshairColor = c.ticks;
    chart.update('none');
  }
}

/* Charts must look right in BOTH themes: restyle when the OS scheme changes. */
window.matchMedia('(prefers-color-scheme: dark)')
  .addEventListener('change', () => requestAnimationFrame(restyleCharts));

/* ------------------------------ history loading ---------------------------- */

/** Push one /api/history response into all six charts (one fetch feeds all). */
function applyHistory(points) {
  lastHistoryTs = points.length ? points[points.length - 1].ts : 0;
  for (const def of CHART_DEFS) {
    const chart = charts[def.field];
    chart.data.datasets[0].data = points.map(p => ({
      x: p.ts * 1000,                              // unix s -> ms for the time scale
      y: p[def.field],                             // may be null -> gap in the line
    }));
    chart.update('none');
  }
}

async function refreshHistory() {
  if (!baseUrl) return;
  const section = document.getElementById('chartsSection');
  section.classList.add('is-refreshing');          // dim, keep the old frame
  try {
    const { status, body } = await getJson(`/api/history?minutes=${rangeMinutes}&max_points=${MAX_POINTS}`);
    setServerReachable(true);
    if (status === 200 && body && Array.isArray(body.points)) applyHistory(body.points);
  } catch {
    setServerReachable(false, baseUrl + '/api/history');
  } finally {
    section.classList.remove('is-refreshing');
  }
}

/**
 * Between 60 s history refreshes, keep short ranges feeling live by appending
 * the newest /api/latest sample. Only for ranges <= 1h — on long ranges one
 * raw point per second would fight the server's downsampled buckets.
 */
function liveAppend(d) {
  if (rangeMinutes > LIVE_APPEND_MAX_MIN) return;
  if (!d.ts || d.ts <= lastHistoryTs) return;      // already covered by history
  lastHistoryTs = d.ts;
  const cutoff = (d.ts - rangeMinutes * 60) * 1000;
  for (const def of CHART_DEFS) {
    const data = charts[def.field].data.datasets[0].data;
    data.push({ x: d.ts * 1000, y: d[def.field] });
    while (data.length && data[0].x < cutoff) data.shift();  // slide the window
    charts[def.field].update('none');
  }
}

/* -------------------------------- pollers ---------------------------------- */

async function pollLatest() {
  if (!baseUrl || latestInFlight) return;
  latestInFlight = true;
  try {
    const { status, body } = await getJson('/api/latest');
    setServerReachable(true);                      // any HTTP answer = server alive
    if (status === 200 && body) {
      lastUpdateAt = Date.now();
      renderLatest(body);
      liveAppend(body);
    } else if (status === 404) {
      renderNoData();                              // empty DB: server ok, no samples
    }
  } catch {
    setServerReachable(false, baseUrl + '/api/latest');
  } finally {
    latestInFlight = false;
  }
}

async function refreshStats() {
  if (!baseUrl) return;
  try {
    const { status, body } = await getJson('/api/stats?hours=24');
    if (status === 200 && body) renderStats(body);
  } catch {
    /* the /api/latest poller owns the pill + banner; stay quiet here */
  }
}

/** (Re)start all polling — called on load and after settings change. */
function startPolling() {
  clearInterval(latestTimer);
  clearInterval(slowTimer);
  if (!baseUrl) {
    setPill('serverPill', 'idle', 'Not configured');
    setPill('devicePill', 'idle', 'Device');
    return;
  }
  serverReachable = null;                          // re-evaluate from scratch
  bannerDismissed = false;
  pollLatest();
  refreshHistory();
  refreshStats();
  latestTimer = setInterval(pollLatest, LATEST_INTERVAL_MS);
  slowTimer   = setInterval(() => { refreshHistory(); refreshStats(); }, SLOW_INTERVAL_MS);
}

/* ----------------------------- range selector ------------------------------ */

document.getElementById('rangeSelect').addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-minutes]');
  if (!btn) return;
  rangeMinutes = Number(btn.dataset.minutes);
  for (const b of btn.parentElement.querySelectorAll('button')) {
    const active = b === btn;
    b.classList.toggle('active', active);
    b.setAttribute('aria-pressed', String(active));
  }
  refreshHistory();                                // one range scopes every chart
});

/* ----------------------------- settings panel ------------------------------ */

const scrim     = document.getElementById('settingsScrim');
const urlInput  = document.getElementById('baseUrlInput');
const mixedWarn = document.getElementById('mixedWarn');
const testResult = document.getElementById('testResult');

function openSettings() {
  urlInput.value = baseUrl;
  updateMixedWarning();
  testResult.textContent = '';
  testResult.className = 'test-result';
  scrim.hidden = false;
  urlInput.focus();
}
function closeSettings() { scrim.hidden = true; }

function updateMixedWarning() {
  mixedWarn.hidden = !isMixedContent(normalizeBaseUrl(urlInput.value));
}

document.getElementById('settingsBtn').addEventListener('click', openSettings);
document.getElementById('closeSettingsBtn').addEventListener('click', closeSettings);
scrim.addEventListener('click', (e) => { if (e.target === scrim) closeSettings(); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !scrim.hidden) closeSettings(); });

urlInput.addEventListener('input', updateMixedWarning);

document.getElementById('saveSettingsBtn').addEventListener('click', () => {
  baseUrl = normalizeBaseUrl(urlInput.value);
  localStorage.setItem(STORAGE_KEY, baseUrl);
  closeSettings();
  startPolling();                                  // apply immediately
});

/* Restore the URL baked into DEFAULT_BASE_URL (does not save until you hit Save). */
document.getElementById('resetUrlBtn').addEventListener('click', () => {
  urlInput.value = DEFAULT_BASE_URL;
  updateMixedWarning();
  testResult.textContent = '';
  testResult.className = 'test-result';
  urlInput.focus();
});

/* "Test connection" pings /api/health with whatever is typed right now. */
document.getElementById('testBtn').addEventListener('click', async () => {
  const url = normalizeBaseUrl(urlInput.value);
  testResult.className = 'test-result';
  if (!url) { testResult.textContent = 'Enter a URL first.'; return; }
  testResult.textContent = 'Testing…';

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    const res  = await fetch(url + '/api/health', { ...FETCH_OPTS, signal: controller.signal });
    const body = await res.json().catch(() => null);
    if (res.ok && body && body.status === 'ok') {
      testResult.textContent = '✓ Connected — server is healthy';
      testResult.classList.add('ok');
    } else {
      testResult.textContent = `✗ Server answered with HTTP ${res.status}`;
      testResult.classList.add('fail');
    }
  } catch {
    testResult.textContent = isMixedContent(url)
      ? '✗ Blocked — see the mixed-content note above'
      : '✗ Could not reach the server (check the URL, port and CORS)';
    testResult.classList.add('fail');
  } finally {
    clearTimeout(timer);
  }
});

/* ---------------------------------- boot ----------------------------------- */

// Build all six charts once; data arrives via applyHistory()/liveAppend().
for (const def of CHART_DEFS) charts[def.field] = makeChart(def);

if (baseUrl) {
  // Normal path: DEFAULT_BASE_URL or a saved override. Start straight away —
  // no settings popup on load, the gear button is there when you need it.
  startPolling();
} else {
  // Only reachable with DEFAULT_BASE_URL empty, or after clearing the field.
  setPill('serverPill', 'idle', 'Not configured');
  setPill('devicePill', 'idle', 'Device');
  openSettings();
}
