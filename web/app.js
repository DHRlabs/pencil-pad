// PencilPad iPad page: Pencil input, the Mac socket, and the toolbar.
// Effects live in fx.js and load after this file, so input never waits on three.js.
// Wire protocol: see AGENTS.md at the repo root.

const WS_PORT = 8711;
const PING_MS = 500;
const DEAD_MS = 3000;     // no frame from the Mac for this long while connected: reconnect
const PAD = 14;          // gap between the active area and the screen edges
const GAP = 12;          // gap between the toolbar and the active area
const STYLES = ['neon', 'aurora', 'ember', 'off'];
const STYLE_NAMES = { neon: 'Neon', aurora: 'Aurora', ember: 'Ember', off: 'Off' };

// Visual event queue shared with fx.js: a ring of fixed-size records, no allocation per event.
export const HOVER = 0, DOWN = 1, MOVE = 2, UP = 3, LEAVE = 4;
const Q_CAP = 1024, Q_STRIDE = 8;
const queue = { buf: new Float64Array(Q_CAP * Q_STRIDE), cap: Q_CAP, stride: Q_STRIDE, head: 0 };

const $ = (id) => document.getElementById(id);
const body = document.body;
const surface = $('surface'), bar = $('bar'), frame = $('area'), areaLabel = $('area-label');
const targetsEl = $('targets'), statusText = $('status-text'), rclickBtn = $('rclick');
const styleBtn = $('style'), styleName = $('style-name'), fsBtn = $('fs'), insetsEl = $('insets');

const token = location.pathname.split('/').filter(Boolean)[0] || '';
const wsURL = `ws://${location.hostname}:${WS_PORT}/`;

// The active area in CSS px; fx.js reads it every frame.
const area = { x: 0, y: 0, w: 1, h: 1 };
const ui = { area, rightArmed: false };

let ws = null, ready = false, halted = '';   // halted: '' | 'denied' | 'replaced'
let backoff = 500, retryTimer = 0, pingTimer = 0, lastRx = 0;
let screens = [], target = null;
let penId = -1, stroke = false, lastX = 0, lastY = 0, lastSX = 0, lastSY = 0;
let tx = 0, ty = 0;
let fx = null;

const store = {
  get(k) { try { return localStorage.getItem('pencilpad.' + k); } catch (_) { return null; } },
  set(k, v) { try { localStorage.setItem('pencilpad.' + k, v); } catch (_) {} },
};

// ---------- Visual queue ----------

function qv(type, sx, sy, p, rx, ry, tilt) {
  const b = queue.buf, o = (queue.head % Q_CAP) * Q_STRIDE;
  b[o] = type; b[o + 1] = sx; b[o + 2] = sy; b[o + 3] = p;
  b[o + 4] = rx; b[o + 5] = ry; b[o + 6] = tilt; b[o + 7] = performance.now();
  queue.head++;
}

// ---------- Mapping ----------

const r5 = (v) => Math.round(v * 1e5) / 1e5;
const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const normX = (x) => r5(clamp01((x - area.x) / area.w));
const normY = (y) => r5(clamp01((y - area.y) / area.h));
const inArea = (x, y) => x >= area.x && x <= area.x + area.w && y >= area.y && y <= area.y + area.h;
const pressure = (e) => Math.round((e.pressure || 0) * 1000) / 1000;

function readTilt(e) {
  tx = e.tiltX || 0; ty = e.tiltY || 0;
  if (!tx && !ty && typeof e.altitudeAngle === 'number' && e.altitudeAngle < Math.PI / 2 - 1e-3) {
    const t = Math.tan(e.altitudeAngle), az = e.azimuthAngle || 0;
    tx = Math.atan(Math.cos(az) / t) * 180 / Math.PI;
    ty = Math.atan(Math.sin(az) / t) * 180 / Math.PI;
  }
  tx = Math.round(tx * 10) / 10; ty = Math.round(ty * 10) / 10;
}

function fit() {
  const W = innerWidth, H = innerHeight, cs = getComputedStyle(insetsEl);
  const it = parseFloat(cs.paddingTop) || 0, ir = parseFloat(cs.paddingRight) || 0;
  const ib = parseFloat(cs.paddingBottom) || 0, il = parseFloat(cs.paddingLeft) || 0;
  const top = Math.max(bar.getBoundingClientRect().bottom, it) + GAP;
  const left = il + PAD, right = W - ir - PAD, bottom = H - ib - PAD;
  const aw = Math.max(1, right - left), ah = Math.max(1, bottom - top);
  const aspect = target && target.w > 0 && target.h > 0 ? target.w / target.h : cachedAspect();
  let w = aw, h = aw / aspect;
  if (h > ah) { h = ah; w = ah * aspect; }
  area.x = left + (aw - w) / 2; area.y = top + (ah - h) / 2; area.w = w; area.h = h;
  const s = frame.style;
  s.left = area.x + 'px'; s.top = area.y + 'px'; s.width = w + 'px'; s.height = h + 'px';
}

function cachedAspect() {
  const a = parseFloat(store.get('aspect'));
  return a > 0 ? a : 16 / 10;
}

// ---------- Pencil input (sends first, visuals queued for the next frame) ----------

const hasCoalesced = typeof PointerEvent !== 'undefined' && 'getCoalescedEvents' in PointerEvent.prototype;

function send(s) { if (ws && ws.readyState === 1) ws.send(s); }

function onDown(e) {
  if (e.pointerType !== 'pen' || penId !== -1) return;
  const x = e.clientX, y = e.clientY;
  if (!inArea(x, y)) return;
  penId = e.pointerId;
  const X = normX(x), Y = normY(y), p = pressure(e);
  readTilt(e);
  if (ready) {
    const b = ui.rightArmed ? 'right' : 'left';
    send(`{"t":"down","x":${X},"y":${Y},"p":${p},"tx":${tx},"ty":${ty},"b":"${b}"}`);
    stroke = true; lastX = X; lastY = Y;
    if (ui.rightArmed) setRight(false);
  }
  e.preventDefault();
  try { surface.setPointerCapture(penId); } catch (_) {}
  lastSX = area.x + X * area.w; lastSY = area.y + Y * area.h;
  qv(DOWN, lastSX, lastSY, p, x, y, tiltMag());
  if (!body.classList.contains('drawn')) body.classList.add('drawn');
}

function movePoint(ev) {
  const x = ev.clientX, y = ev.clientY, X = normX(x), Y = normY(y), p = pressure(ev);
  readTilt(ev);
  if (stroke) {
    send(`{"t":"move","x":${X},"y":${Y},"p":${p},"tx":${tx},"ty":${ty}}`);
    lastX = X; lastY = Y;
  }
  lastSX = area.x + X * area.w; lastSY = area.y + Y * area.h;
  qv(MOVE, lastSX, lastSY, p, x, y, tiltMag());
}

function onMove(e) {
  if (e.pointerType !== 'pen') return;
  if (e.pointerId === penId) {
    if (e.buttons === 0) { onUp(e); return; }   // lifted without a pointerup: release now
    const list = hasCoalesced ? e.getCoalescedEvents() : null;
    if (list && list.length) for (let i = 0; i < list.length; i++) movePoint(list[i]);
    else movePoint(e);
    return;
  }
  if (penId !== -1 || e.buttons !== 0) return;
  const x = e.clientX, y = e.clientY;
  if (ready && inArea(x, y)) send(`{"t":"hover","x":${normX(x)},"y":${normY(y)}}`);
  qv(HOVER, x, y, 0, x, y, 0);
}

function onUp(e) {
  if (e.pointerId !== penId) return;
  if (e.type === 'pointerup' || e.type === 'pointermove') { lastX = normX(e.clientX); lastY = normY(e.clientY); }
  if (stroke) send(`{"t":"up","x":${lastX},"y":${lastY}}`);
  stroke = false; penId = -1;
  qv(UP, lastSX, lastSY, 0, e.clientX || lastSX, e.clientY || lastSY, 0);
}

function onLeave(e) {
  if (e.pointerType === 'pen' && penId === -1) qv(LEAVE, 0, 0, 0, 0, 0, 0);
}

// Close any open stroke: hidden page, lost focus, socket teardown.
function releaseStroke() {
  if (stroke) send(`{"t":"up","x":${lastX},"y":${lastY}}`);
  if (penId !== -1) qv(UP, lastSX, lastSY, 0, lastSX, lastSY, 0);
  stroke = false; penId = -1;
}

function tiltMag() { return Math.min(90, Math.hypot(tx, ty)); }

surface.addEventListener('pointerdown', onDown);
surface.addEventListener('pointermove', onMove);
surface.addEventListener('pointerup', onUp);
surface.addEventListener('pointercancel', onUp);
surface.addEventListener('lostpointercapture', onUp);
surface.addEventListener('pointerleave', onLeave);

// Kill Safari's own gestures everywhere except on buttons.
const notButton = (e) => !(e.target instanceof Element && e.target.closest('button'));
const block = (e) => { if (notButton(e)) e.preventDefault(); };
document.addEventListener('touchstart', block, { passive: false });
document.addEventListener('touchmove', block, { passive: false });
for (const t of ['gesturestart', 'gesturechange', 'gestureend']) document.addEventListener(t, (e) => e.preventDefault(), { passive: false });
document.addEventListener('dblclick', (e) => e.preventDefault(), { passive: false });
document.addEventListener('contextmenu', (e) => e.preventDefault());
document.addEventListener('selectstart', (e) => e.preventDefault());

// Stuck-button safety.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') releaseStroke();
  else if (!halted && (!ws || ws.readyState > 1)) { backoff = 500; connect(); }
});
addEventListener('pagehide', releaseStroke);
addEventListener('blur', releaseStroke);
addEventListener('pageshow', (e) => { if (e.persisted && !halted) { backoff = 500; connect(); } });

// ---------- Socket ----------

function setConn(state, text) {
  body.dataset.conn = state;
  statusText.textContent = text;
}

function connect() {
  clearTimeout(retryTimer);
  releaseStroke();
  if (ws) {
    ws.onopen = ws.onmessage = ws.onclose = ws.onerror = null;
    try { ws.close(); } catch (_) {}
  }
  clearInterval(pingTimer);
  ready = false;
  if (body.dataset.conn !== 'retry') setConn('connecting', 'Connecting');
  const s = new WebSocket(wsURL);
  ws = s;
  s.onopen = () => {
    lastRx = performance.now();
    s.send(JSON.stringify({ t: 'hello', token }));
    pingTimer = setInterval(() => {
      if (s.readyState !== 1) return;
      if (performance.now() - lastRx > DEAD_MS) { retry(s); return; }   // the Mac went silent: the socket is dead
      s.send('{"t":"ping"}');
    }, PING_MS);
  };
  s.onmessage = (e) => { lastRx = performance.now(); onMessage(e.data); };
  s.onerror = () => {};
  s.onclose = () => { if (ws === s) retry(s); };
}

// Drop this socket and try again with backoff, unless the Mac told us to stop.
function retry(s) {
  releaseStroke();   // sends up while a silent socket can still carry it; a closed one only ends the stroke locally
  s.onopen = s.onmessage = s.onclose = s.onerror = null;
  try { s.close(); } catch (_) {}
  clearInterval(pingTimer);
  ready = false; ws = null;
  if (halted) return;
  setConn('retry', 'Reconnecting');
  retryTimer = setTimeout(connect, backoff);
  backoff = Math.min(5000, Math.round(backoff * 1.7));
}

// Denied (wrong link) and replaced (another page took over) both stop retrying.
function halt(kind, text) {
  halted = kind; ready = false;
  stroke = false; releaseStroke();   // the Mac already let go; end the stroke on this side only
  clearTimeout(retryTimer); clearInterval(pingTimer);
  setConn(kind, text);
  $(kind).hidden = false;
  try { ws && ws.close(); } catch (_) {}
}

function onMessage(data) {
  let m;
  try { m = JSON.parse(data); } catch (_) { return; }
  switch (m.t) {
    case 'hello':
      ready = true; backoff = 500;
      screens = Array.isArray(m.screens) ? m.screens : [];
      setConn('live', 'Connected');
      renderTargets();
      setTarget(m.target || screens.find((s) => s.main) || screens[0] || null);
      break;
    case 'screens':
      screens = Array.isArray(m.screens) ? m.screens : [];
      renderTargets();
      markTarget();
      break;
    case 'target':
      setTarget(m.target);
      break;
    case 'denied':
      halt('denied', 'Wrong link');
      break;
    case 'replaced':
      halt('replaced', 'Open elsewhere');
      break;
  }
}

// ---------- Targets ----------

function shortName(s) {
  return /built-?in|color lcd/i.test(s.name || '') ? 'Laptop' : (s.name || 'Screen');
}

function renderTargets() {
  targetsEl.textContent = '';
  const seen = {};
  const add = (label, id, title) => {
    const n = (seen[label] = (seen[label] || 0) + 1);
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'chip'; b.dataset.id = id; b.title = title;
    const span = document.createElement('span');
    span.textContent = n > 1 ? `${label} ${n}` : label;
    b.append(span);
    targetsEl.append(b);
  };
  for (const s of screens) add(shortName(s), s.id, `${s.name} · ${s.w}×${s.h}`);
  add('Window', 'window', "The Mac's front window");
  markTarget();
}

function activeTargetId() {
  if (!target) return null;
  return screens.some((s) => s.id === target.id) ? target.id : 'window';
}

function markTarget() {
  const id = activeTargetId();
  for (const b of targetsEl.children) {
    b.classList.toggle('active', b.dataset.id === id);
    b.classList.remove('pending');
  }
}

function setTarget(t) {
  if (!t) return;
  target = t;
  if (t.w > 0 && t.h > 0) store.set('aspect', String(t.w / t.h));
  const s = screens.find((x) => x.id === t.id);
  areaLabel.textContent = `${s ? shortName(s) : t.name || 'Window'} · ${Math.round(t.w)}×${Math.round(t.h)}`;
  markTarget();
  fit();
}

targetsEl.addEventListener('click', (e) => {
  const b = e.target.closest('.chip');
  if (!b || !ready) return;
  send(`{"t":"target","id":${JSON.stringify(b.dataset.id)}}`);
  if (!b.classList.contains('active')) b.classList.add('pending');
});

// ---------- Buttons ----------

// A toolbar press that starts while the Pencil is down is a palm or a slip: swallow it before any button sees it.
let pressDuringStroke = false;
bar.addEventListener('pointerdown', () => { pressDuringStroke = penId !== -1; }, true);
bar.addEventListener('click', (e) => {
  if (penId !== -1 || pressDuringStroke) { e.stopPropagation(); e.preventDefault(); }
}, true);

for (const b of bar.querySelectorAll('[data-key]')) {
  b.addEventListener('click', () => { if (ready) send(`{"t":"key","name":"${b.dataset.key}"}`); });
}

function setRight(on) {
  ui.rightArmed = on;
  rclickBtn.classList.toggle('armed', on);
  rclickBtn.setAttribute('aria-pressed', String(on));
  body.classList.toggle('rarmed', on);
}
rclickBtn.addEventListener('click', () => setRight(!ui.rightArmed));

let style = STYLES.includes(store.get('style')) ? store.get('style') : 'neon';
function applyStyle() {
  body.dataset.style = style;
  styleName.textContent = STYLE_NAMES[style];
  styleBtn.title = `Effects: ${STYLE_NAMES[style]}`;
  store.set('style', style);
  if (fx) fx.setStyle(style);
}
styleBtn.addEventListener('click', () => {
  style = STYLES[(STYLES.indexOf(style) + 1) % STYLES.length];
  applyStyle();
});

$('clear').addEventListener('click', () => { if (fx) fx.clear(); });

const de = document.documentElement;
const requestFS = de.requestFullscreen || de.webkitRequestFullscreen;
const exitFS = document.exitFullscreen || document.webkitExitFullscreen;
const fsElement = () => document.fullscreenElement || document.webkitFullscreenElement;
const standalone = navigator.standalone === true ||
  matchMedia('(display-mode: standalone)').matches || matchMedia('(display-mode: fullscreen)').matches;
fsBtn.hidden = standalone || !requestFS || !(document.fullscreenEnabled || document.webkitFullscreenEnabled);
fsBtn.addEventListener('click', () => {
  const r = fsElement() ? exitFS.call(document) : requestFS.call(de);
  if (r && r.catch) r.catch(() => {});
});
const onFS = () => { body.classList.toggle('fs', !!fsElement()); fit(); };
document.addEventListener('fullscreenchange', onFS);
document.addEventListener('webkitfullscreenchange', onFS);

$('tuck').addEventListener('click', () => {
  const t = bar.classList.toggle('tucked');
  $('tuck').title = t ? 'Show toolbar' : 'Hide toolbar';
  store.set('tucked', t ? '1' : '');
  fit();
});
if (store.get('tucked')) bar.classList.add('tucked');

$('retry').addEventListener('click', () => location.reload());
$('takeover').addEventListener('click', () => {
  $('replaced').hidden = true;
  halted = ''; backoff = 500;
  connect();   // the newest page wins, so this takes the Mac back
});

addEventListener('resize', fit);
addEventListener('orientationchange', () => requestAnimationFrame(fit));

// ---------- Start ----------

applyStyle();
fit();
connect();

import('./fx.js')
  .then((m) => { fx = m.start({ canvas: $('fx'), queue, ui }); fx.setStyle(style); })
  .catch((err) => { console.warn('PencilPad: effects unavailable, input still works.', err); body.classList.add('nofx'); });
