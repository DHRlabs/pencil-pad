// PencilPad iPad page: Pencil input, the Mac socket, and the toolbar.
// Effects live in fx.js and load after this file, so input never waits on three.js.
// Wire protocol: see AGENTS.md at the repo root.

// board-core.js is a classic script loaded by index.html before this module (see its header). If it
// failed to load, Board is switched off and Mouse mode runs exactly as before.
const core = globalThis.PencilBoardCore || null;
const { createBoard, createView, BGS } = core || {};

const WS_PORT = Number(location.port || 8710) + 1;   // the socket is always the page port + 1
const PING_MS = 500;
const DEAD_MS = 3000;     // no frame from the Mac for this long while connected: reconnect
const PAD = 14;          // gap between the active area and the screen edges
const GAP = 12;          // gap between the toolbar and the active area
const STYLES = ['neon', 'aurora', 'ember', 'off'];
const STYLE_NAMES = { neon: 'Neon', aurora: 'Aurora', ember: 'Ember', off: 'Off' };

// Aim (Wacom tip threshold): a touch lighter than this moves the cursor without clicking.
// Safari reports Pencil pressure as force / maximum force: a light glide sits around 0.03 to 0.12,
// normal writing around 0.2 to 0.35. Soft sits at the top of the glide band, so any deliberate
// stroke clicks; Firm sits inside the writing band, so resting the tip with some weight still aims.
const AIM_AT = { off: 0, soft: 0.12, firm: 0.25 };
const AIM_MODES = ['off', 'soft', 'firm'];
const AIM_NAMES = { off: 'Off', soft: 'Soft', firm: 'Firm' };
// A touch wider than this (CSS px across) on the toolbar or the window list is a resting palm, not a fingertip, and does nothing.
// A guess for a fingertip on iPad glass: it may need tuning on the real iPad.
const PALM_PX = 30;
const HOVER_CONFIRM_MS = 100;   // hardware hover counts once 3+ pen hover moves span this long with no touch between

// Visual event queue shared with fx.js: a ring of fixed-size records, no allocation per event.
export const HOVER = 0, DOWN = 1, MOVE = 2, UP = 3, LEAVE = 4, AIM = 5;
const Q_CAP = 1024, Q_STRIDE = 8;
const queue = { buf: new Float64Array(Q_CAP * Q_STRIDE), cap: Q_CAP, stride: Q_STRIDE, head: 0 };

const $ = (id) => document.getElementById(id);
const body = document.body;
const surface = $('surface'), bar = $('bar'), frame = $('area'), areaLabel = $('area-label');
const targetsEl = $('targets'), statusText = $('status-text'), rclickBtn = $('rclick');
const styleBtn = $('style'), styleName = $('style-name'), fsBtn = $('fs'), insetsEl = $('insets');
const aimBtn = $('aim'), aimName = $('aim-name'), winMenu = $('winmenu');

const token = location.pathname.split('/').filter(Boolean)[0] || '';
const wsURL = `ws://${location.hostname}:${WS_PORT}/`;

// The active area in CSS px; fx.js reads it every frame.
const area = { x: 0, y: 0, w: 1, h: 1 };
const ui = { area, rightArmed: false };

let ws = null, ready = false, halted = '';   // halted: '' | 'denied' | 'replaced'
let boardOpen = null;        // Board window state the Mac reported on this connection (it sends one after every hello); null = not heard yet
let stateOnConn = false;     // the Mac has reported the window state on this connection
let replayAnswered = false;  // this page has answered a replay request on this connection
let backoff = 500, retryTimer = 0, pingTimer = 0, lastRx = 0;
let screens = [], target = null;
let penId = -1, stroke = false, lastX = 0, lastY = 0, lastSX = 0, lastSY = 0;
let aiming = false, aimX = 0, aimY = 0, aimP = 0, aimPending = false;   // Pencil touching below the aim threshold
let hoverStart = 0, hoverCount = 0;
// A Pencil without pressure hardware reports 0 forever and could never cross a threshold, so Aim
// acts as Off until this device has shown a pen pressure above 0 (remembered like the hover dot).
let pressureSeen = false;
let tx = 0, ty = 0;
let fx = null;

const store = {
  get(k) { try { return localStorage.getItem('pencilpad.' + k); } catch (_) { return null; } },
  set(k, v) { try { localStorage.setItem('pencilpad.' + k, v); } catch (_) {} },
};

// ---------- Visual queue ----------

// aux: tilt magnitude for pen points, aim progress (pressure / threshold, 0 to 1) for AIM.
function qv(type, sx, sy, p, rx, ry, aux) {
  const b = queue.buf, o = (queue.head % Q_CAP) * Q_STRIDE;
  b[o] = type; b[o + 1] = sx; b[o + 2] = sy; b[o + 3] = p;
  b[o + 4] = rx; b[o + 5] = ry; b[o + 6] = aux; b[o + 7] = performance.now();
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
  const aspect = mode === 'board' ? 16 / 9
    : target && target.w > 0 && target.h > 0 ? target.w / target.h : cachedAspect();
  let w = aw, h = aw / aspect;
  if (h > ah) { h = ah; w = ah * aspect; }
  area.x = left + (aw - w) / 2; area.y = top + (ah - h) / 2; area.w = w; area.h = h;
  const s = frame.style;
  s.left = area.x + 'px'; s.top = area.y + 'px'; s.width = w + 'px'; s.height = h + 'px';
  areaLabel.textContent = mode === 'board' ? 'Board · 16:9' : targetLabel();
  placeInk();
  placeWinMenu();
}

function cachedAspect() {
  const a = parseFloat(store.get('aspect'));
  return a > 0 ? a : 16 / 10;
}

// ---------- Pencil input (sends first, visuals queued for the next frame) ----------

const hasCoalesced = typeof PointerEvent !== 'undefined' && 'getCoalescedEvents' in PointerEvent.prototype;

function send(s) { if (ws && ws.readyState === 1) ws.send(s); }

function aimAt() { return pressureSeen ? AIM_AT[aimMode] : 0; }

function notePressure(p) {
  if (pressureSeen || !(p > 0)) return;
  pressureSeen = true;
  store.set('pressureSeen', '1');
  applyAim();
}

function sendDown(X, Y, p) {
  const b = ui.rightArmed ? 'right' : 'left';
  send(`{"t":"down","x":${X},"y":${Y},"p":${p},"tx":${tx},"ty":${ty},"b":"${b}"}`);
  stroke = true; lastX = X; lastY = Y;
  if (ui.rightArmed) setRight(false);   // only a real down uses up the right-click
}

// The tip crossed the threshold (or Aim is off): click here with the real pressure.
function pressAt(x, y, p) {
  const X = normX(x), Y = normY(y);
  aiming = false; aimPending = false;
  if (ready) sendDown(X, Y, p);
  lastSX = area.x + X * area.w; lastSY = area.y + Y * area.h;
  qv(DOWN, lastSX, lastSY, p, x, y, tiltMag());
}

// Below the threshold: the cursor follows, one hover per event.
function flushAim() {
  if (!aimPending) return;
  aimPending = false;
  const X = normX(aimX), Y = normY(aimY);
  if (ready && inArea(aimX, aimY)) send(`{"t":"hover","x":${X},"y":${Y}}`);   // outside the area only the reticle follows
  qv(AIM, area.x + X * area.w, area.y + Y * area.h, aimP, aimX, aimY, Math.min(1, aimP / aimAt()));
}

function onDown(e) {
  if (e.pointerType !== 'pen' || penId !== -1) return;
  const x = e.clientX, y = e.clientY;
  if (!inArea(x, y)) return;
  penId = e.pointerId; hoverStart = 0; hoverCount = 0;
  const p = pressure(e);
  notePressure(p);
  readTilt(e);
  e.preventDefault();
  try { surface.setPointerCapture(penId); } catch (_) {}
  if (mode === 'board') { boardDown(e, x, y); return; }   // Board: ink, never mouse
  if (p >= aimAt()) pressAt(x, y, p);
  else { aiming = true; aimX = x; aimY = y; aimP = p; aimPending = true; flushAim(); }
  if (!body.classList.contains('drawn')) body.classList.add('drawn');
}

function contactPoint(ev) {
  if (aiming) {
    const p = pressure(ev);
    readTilt(ev);
    if (p >= aimAt() && inArea(ev.clientX, ev.clientY)) { pressAt(ev.clientX, ev.clientY, p); return; }   // clicks start inside the area
    aimX = ev.clientX; aimY = ev.clientY; aimP = p; aimPending = true;
    return;
  }
  movePoint(ev);
}

function movePoint(ev) {
  const x = ev.clientX, y = ev.clientY, X = normX(x), Y = normY(y), p = pressure(ev);
  notePressure(p);
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
    if (mode === 'board') { boardMove(e); return; }   // Board: ink locally, no mouse messages
    const list = hasCoalesced ? e.getCoalescedEvents() : null;
    if (list && list.length) for (let i = 0; i < list.length; i++) contactPoint(list[i]);
    else contactPoint(e);
    flushAim();
    return;
  }
  if (penId !== -1 || e.buttons !== 0) return;
  const x = e.clientX, y = e.clientY;
  if (ready && mode === 'mouse' && inArea(x, y)) send(`{"t":"hover","x":${normX(x)},"y":${normY(y)}}`);
  qv(HOVER, x, y, 0, x, y, 0);
  noteHover();
}

function onUp(e) {
  if (e.pointerId !== penId) return;
  if (mode === 'board') { boardUp(); return; }
  if (e.type === 'pointerup' || e.type === 'pointermove') { lastX = normX(e.clientX); lastY = normY(e.clientY); }
  if (stroke) send(`{"t":"up","x":${lastX},"y":${lastY}}`);   // an aim-only touch sends nothing on lift
  stroke = false; penId = -1; aiming = false; aimPending = false; hoverStart = 0; hoverCount = 0;
  qv(UP, lastSX, lastSY, 0, e.clientX || lastSX, e.clientY || lastSY, 0);
}

// Hardware hover (Pencil above the glass) is noted on the Aim chip once seen; nothing is sent for it.
function noteHover() {
  if (aimBtn.classList.contains('hover')) return;
  const now = performance.now();
  if (!hoverStart) hoverStart = now;
  if (++hoverCount < 3 || now - hoverStart < HOVER_CONFIRM_MS) return;
  aimBtn.classList.add('hover');
  aimBtn.title = aimTitle();
  store.set('hoverSeen', '1');
}

function onLeave(e) {
  if (e.pointerType === 'pen' && penId === -1) { hoverStart = 0; hoverCount = 0; qv(LEAVE, 0, 0, 0, 0, 0, 0); }
}

// Close any open stroke: hidden page, lost focus, socket teardown.
function releaseStroke() {
  if (mode === 'board') boardLift();
  if (stroke) send(`{"t":"up","x":${lastX},"y":${lastY}}`);
  if (penId !== -1 && mode !== 'board') qv(UP, lastSX, lastSY, 0, lastSX, lastSY, 0);
  stroke = false; penId = -1; aiming = false; aimPending = false;
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
  ready = false; macLost();
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
  ready = false; macLost(); ws = null;
  if (halted) return;
  setConn('retry', 'Reconnecting');
  retryTimer = setTimeout(connect, backoff);
  backoff = Math.min(5000, Math.round(backoff * 1.7));
}

// Denied (wrong link) and replaced (another page took over) both stop retrying.
function halt(kind, text) {
  halted = kind; ready = false; macLost();
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
    case 'windows':
      showWindows(m.list);
      break;
    case 'denied':
      halt('denied', 'Wrong link');
      break;
    case 'replaced':
      halt('replaced', 'Open elsewhere');
      break;
    case 'board':
      onBoard(m);
      break;
  }
}

// ---------- Targets ----------

function shortName(s) {
  return /built-?in|color lcd/i.test(s.name || '') ? 'Laptop' : (s.name || 'Screen');
}

let winChip = null;   // the Window chip, rebuilt with the others

function renderTargets() {
  targetsEl.textContent = '';
  winChip = null;
  const seen = {};
  const add = (label, id, title) => {
    const n = (seen[label] = (seen[label] || 0) + 1);
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'chip'; b.dataset.id = id; b.title = title;
    const span = document.createElement('span');
    span.textContent = n > 1 ? `${label} ${n}` : label;
    b.append(span);
    if (id === 'window') {
      winChip = b;
      b.setAttribute('aria-haspopup', 'menu');
      const caret = document.createElement('i');
      caret.className = 'caret';
      b.append(caret);
    }
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
  if (id !== 'window') closeWinMenu();
  if (winChip) {
    // A window target shows its app on the chip; a second tap on it chooses another window.
    winChip.firstChild.textContent = id === 'window' && target.app ? target.app : 'Window';
    winChip.title = id === 'window' ? `${target.name}. Tap to choose another window` : "The Mac's front window";
    if (id === 'window') winChip.setAttribute('aria-expanded', String(!winMenu.hidden));
    else winChip.removeAttribute('aria-expanded');
  }
}

function targetLabel() {
  if (!target) return '';
  const s = screens.find((x) => x.id === target.id);
  return `${s ? shortName(s) : target.name || 'Window'} · ${Math.round(target.w)}×${Math.round(target.h)}`;
}

function setTarget(t) {
  if (!t) return;
  target = t;
  if (t.w > 0 && t.h > 0) store.set('aspect', String(t.w / t.h));
  const s = screens.find((x) => x.id === t.id);
  markTarget();
  fit();
}

targetsEl.addEventListener('click', (e) => {
  const b = e.target.closest('.chip');
  if (!b || !ready) return;
  if (b === winChip && activeTargetId() === 'window') { toggleWinMenu(); return; }   // second tap: which window?
  closeWinMenu();
  send(`{"t":"target","id":${JSON.stringify(b.dataset.id)}}`);
  if (!b.classList.contains('active')) b.classList.add('pending');
});

// ---------- Window picker ----------

// Tapping Window while a window is already the target asks the Mac for its windows and lists them under the
// chip, front first, the current one checked. A row asks the Mac to bring that window forward and target it.
function toggleWinMenu() {
  if (!winMenu.hidden) { closeWinMenu(); return; }
  winMenu.hidden = false;
  winNote('Loading windows…');
  winChip.setAttribute('aria-expanded', 'true');
  placeWinMenu();
  send('{"t":"windows"}');
}

function closeWinMenu() {
  if (winMenu.hidden) return;
  winMenu.hidden = true;
  winMenu.textContent = '';
  if (winChip) winChip.setAttribute('aria-expanded', 'false');
}

function winNote(text) {
  winMenu.textContent = '';
  const n = document.createElement('div');
  n.className = 'note'; n.textContent = text;
  winMenu.append(n);
}

function showWindows(list) {
  if (winMenu.hidden) return;   // closed before the Mac answered
  if (!Array.isArray(list) || !list.length) { winNote('No windows'); placeWinMenu(); return; }
  winMenu.textContent = '';
  const text = (w) => (w.title ? `${w.app}: ${w.title}` : w.app);   // window titles are the Mac's data: text only
  const seen = {};
  for (const w of list) seen[text(w)] = (seen[text(w)] || 0) + 1;
  for (const w of list) {
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'row'; b.dataset.id = w.id;
    b.setAttribute('role', 'menuitemradio');
    b.setAttribute('aria-checked', String(w.current === true));
    const tick = document.createElement('i'); tick.className = 'tick';
    const label = document.createElement('span');
    label.textContent = seen[text(w)] > 1 ? `${text(w)} (${w.w}×${w.h})` : text(w);   // two alike: the size tells them apart
    b.append(tick, label);
    winMenu.append(b);
  }
  placeWinMenu();
}

// Under the toolbar, left edge on the chip, kept on screen; scrolls when the list is longer than the room.
function placeWinMenu() {
  if (winMenu.hidden || !winChip) return;
  const top = Math.round(bar.getBoundingClientRect().bottom + 8);
  winMenu.style.top = top + 'px';
  winMenu.style.maxHeight = Math.max(88, innerHeight - top - 14) + 'px';
  winMenu.style.left = Math.round(Math.max(10, Math.min(winChip.getBoundingClientRect().left, innerWidth - winMenu.offsetWidth - 10))) + 'px';
}

winMenu.addEventListener('click', (e) => {
  const b = e.target.closest('.row');
  if (!b || !ready) return;
  send(`{"t":"target","id":"window","pick":${Number(b.dataset.id)}}`);
  if (winChip) winChip.classList.add('pending');   // until the Mac answers with the target
  closeWinMenu();
});

// An outside tap closes the list. A Pencil down on the drawing surface that only dismisses it is swallowed,
// so closing the list never clicks on the Mac.
document.addEventListener('pointerdown', (e) => {
  if (winMenu.hidden || winMenu.contains(e.target) || (winChip && winChip.contains(e.target))) return;
  closeWinMenu();
  if (e.target === surface) { e.stopPropagation(); e.preventDefault(); }
}, true);

// ---------- Buttons ----------

// A toolbar press that starts while the Pencil is down is a palm or a slip: swallow it before any button sees it.
// The same guard covers a palm-sized contact or a second finger: Touch radii are half the contact's size.
let pressDuringStroke = false;
const palmSized = (e) => e.pointerType === 'touch' && Math.max(e.width, e.height) > PALM_PX;
const palmTouch = (e) => e.touches.length > 1 || [...e.changedTouches].some((t) => 2 * Math.max(t.radiusX || 0, t.radiusY || 0) > PALM_PX);
for (const el of [bar, winMenu]) {
  el.addEventListener('pointerdown', (e) => {
    if (e.isPrimary) pressDuringStroke = false;   // a later finger of the same press keeps what the first one decided
    if (penId !== -1 || palmSized(e)) pressDuringStroke = true;
  }, true);
  el.addEventListener('touchstart', (e) => { if (palmTouch(e)) pressDuringStroke = true; }, { capture: true, passive: true });
  el.addEventListener('click', (e) => {
    if (penId !== -1 || pressDuringStroke) { e.stopPropagation(); e.preventDefault(); }
  }, true);
}

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

let aimMode = AIM_MODES.includes(store.get('aim')) ? store.get('aim') : 'soft';
function aimTitle() {
  const what = aimMode === 'off' ? 'Aim off: every Pencil touch clicks'
    : !pressureSeen ? `Aim ${AIM_NAMES[aimMode]} waits for Pencil pressure: until this Pencil reports pressure, every touch clicks`
    : `Aim ${AIM_NAMES[aimMode]}: a light touch moves the cursor, press harder to click`;
  return aimBtn.classList.contains('hover') ? what + ' (this Pencil hovers)' : what;
}
function applyAim() {
  aimName.textContent = AIM_NAMES[aimMode];
  aimBtn.dataset.mode = aimMode;
  aimBtn.classList.toggle('nopressure', !pressureSeen && aimMode !== 'off');
  aimBtn.title = aimTitle();
  aimBtn.setAttribute('aria-label', aimBtn.title);
  store.set('aim', aimMode);
}
aimBtn.addEventListener('click', () => {
  aimMode = AIM_MODES[(AIM_MODES.indexOf(aimMode) + 1) % AIM_MODES.length];
  applyAim();
});
if (store.get('hoverSeen')) aimBtn.classList.add('hover');
pressureSeen = store.get('pressureSeen') === '1';

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
  closeWinMenu();
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

// ---------- Board mode ----------

// The Pencil draws persistent ink on a 16:9 board that mirrors the Mac Board window (web/board.html)
// through the same board-core.js. The iPad owns the board: it applies every op locally, keeps a
// snapshot in localStorage, and sends each op to the Mac, which forwards it to the window. While
// Board is on, no mouse or key message leaves the page.

const COLORS = ['#ffffff', '#000000', '#ff453a', '#ff9f0a', '#ffd60a', '#32d74b', '#0a84ff', '#bf5af2'];
const SIZES = [['s', 0.0028], ['m', 0.0048], ['l', 0.0078]];   // pen width, fraction of the board width
const ERASE_R = 0.014;      // eraser reach, fraction of the board width
const PTS_CAP = 1000;       // most points in one live pts frame (about 26 KB; the limit is 60 KB)
const ERASE_CAP = 4000;     // most stroke ids in one erase frame

const ink = $('ink'), inkCtx = ink.getContext('2d');
const breopen = $('breopen'), toastEl = $('toast'), hintEl = $('hint');
const hintTitle = hintEl.querySelector('strong'), hintText = hintEl.querySelector('span');
const modeBtns = [...bar.querySelectorAll('[data-m]')];
const toolBtns = [...bar.querySelectorAll('[data-b="pen"],[data-b="marker"],[data-b="eraser"]')];
const colorBtns = [...bar.querySelectorAll('[data-c]')], sizeBtns = [...bar.querySelectorAll('[data-s]')];
const undoBtn = bar.querySelector('[data-b="undo"]'), redoBtn = bar.querySelector('[data-b="redo"]');

let mode = core && store.get('mode') === 'board' ? 'board' : 'mouse';
if (!core) body.classList.add('noboard');
try { localStorage.removeItem('pencilpad.boardopen'); } catch (_) {}   // an earlier build remembered the window state; the Mac is the truth now
let bTool = ['pen', 'marker', 'eraser'].includes(store.get('btool')) ? store.get('btool') : 'pen';
let bColor = COLORS.includes(store.get('bcolor')) ? store.get('bcolor') : '#ffffff';
let bSize = SIZES.some(([, v]) => v === Number(store.get('bsize'))) ? Number(store.get('bsize')) : 0.0048;

const board = core ? createBoard() : null, view = core ? createView() : null;
if (board) board.onImage = () => wake();   // a pasted image finished loading: draw it
let bLive = null, bErasing = false;   // open stroke id, eraser drag
let bPending = [], bErase = new Set();   // points and stroke ids waiting for this frame's flush

const lightBg = () => board.bg === 'white' || board.bg === 'grid';
// White ink on the white board draws black and black ink on the dark board draws white.
const inkColor = () => (lightBg() ? (bColor === '#ffffff' ? '#000000' : bColor) : (bColor === '#000000' ? '#ffffff' : bColor));

// ---------- Ink canvas (the board, over the three.js background) ----------

let inkRaf = 0, dirtyUntil = 0;
const sparks = [];
let tip = { x: 0, y: 0, on: false, c: '#ffffff' }, lastTip = null;

function placeInk() {
  const dpr = Math.min(3, window.devicePixelRatio || 1);
  const s = ink.style;
  s.left = area.x + 'px'; s.top = area.y + 'px'; s.width = area.w + 'px'; s.height = area.h + 'px';
  if (mode !== 'board') return;   // the bitmap only matters while Board is showing
  const w = Math.max(1, Math.round(area.w * dpr)), h = Math.max(1, Math.round(area.h * dpr));
  if (ink.width !== w || ink.height !== h) { ink.width = w; ink.height = h; }
  wake(450);   // the frame glides for about 280 ms; keep painting until it settles
}

// One frame loop: flush this frame's points and erases, then paint. It stops by itself when idle.
function wake(ms = 0) {
  dirtyUntil = Math.max(dirtyUntil, performance.now() + ms);
  if (!inkRaf) inkRaf = requestAnimationFrame(inkFrame);
}

function inkFrame() {
  inkRaf = 0;
  bFlush();
  drawInk();
  if (!inkRaf && (sparks.length || performance.now() < dirtyUntil)) inkRaf = requestAnimationFrame(inkFrame);
}

function drawInk() {
  const w = ink.width, h = ink.height;
  if (!w || !h || mode !== 'board') return;
  view.draw(board, inkCtx, w, h);   // the board itself: identical to the Mac window
  // A subtle glow at the tip while inking, plus a few motes. Drawn over the board each frame, never into it.
  const k = w / area.w, light = lightBg();
  inkCtx.save();
  inkCtx.globalCompositeOperation = light ? 'source-over' : 'lighter';
  for (let i = sparks.length - 1; i >= 0; i--) {
    const p = sparks[i];
    p.x += p.vx * 0.016; p.y += p.vy * 0.016; p.vy += 50 * 0.016; p.life -= 0.016 * 2.4;
    if (p.life <= 0) { sparks.splice(i, 1); continue; }
    inkCtx.globalAlpha = (light ? 0.5 : 0.45) * p.life;
    inkCtx.fillStyle = p.c;
    inkCtx.beginPath(); inkCtx.arc(p.x, p.y, (0.8 + 1.8 * p.life) * k, 0, 6.2832); inkCtx.fill();
  }
  if (tip.on) {
    inkCtx.globalAlpha = 1;
    if (bTool === 'eraser') {
      inkCtx.strokeStyle = light ? 'rgba(20,24,40,0.55)' : 'rgba(255,255,255,0.6)';
      inkCtx.lineWidth = Math.max(1, k * 1.2);
      inkCtx.beginPath(); inkCtx.arc(tip.x, tip.y, ERASE_R * w, 0, 6.2832); inkCtx.stroke();
    } else {
      const R = 24 * k, g = inkCtx.createRadialGradient(tip.x, tip.y, 0, tip.x, tip.y, R);
      g.addColorStop(0, light ? hexA(tip.c, 0.28) : 'rgba(255,255,255,0.42)');
      g.addColorStop(0.45, hexA(tip.c, light ? 0.12 : 0.2));
      g.addColorStop(1, hexA(tip.c, 0));
      inkCtx.fillStyle = g;
      inkCtx.beginPath(); inkCtx.arc(tip.x, tip.y, R, 0, 6.2832); inkCtx.fill();
    }
  }
  inkCtx.restore();
}

function hexA(hex, a) {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}

// Pointer position in ink bitmap pixels.
const bx = (clientX) => (clientX - area.x) / area.w * ink.width;
const by = (clientY) => (clientY - area.y) / area.h * ink.height;

function mote(x, y) {
  if (lastTip && Math.hypot(x - lastTip.x, y - lastTip.y) > 4 && sparks.length < 24) {
    const a = Math.atan2(y - lastTip.y, x - lastTip.x) + Math.PI + (Math.random() - 0.5);
    const v = (30 + Math.random() * 90) * (ink.width / area.w);
    sparks.push({ x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v - 20, life: 0.9, c: tip.c });
  }
  lastTip = { x, y };
}

// ---------- Board ops: apply locally, remember, send ----------

let saveTimer = 0, saveFailed = false, saveDeferred = false;
function saveSoon() { clearTimeout(saveTimer); saveTimer = setTimeout(saveNow, 300); }
function saveNow() {
  clearTimeout(saveTimer); saveTimer = 0;
  if (penId !== -1) { saveDeferred = true; return; }   // never stall a stroke; boardLift saves after the Pencil lifts
  saveDeferred = false;
  try { localStorage.setItem('pencilpad.board', JSON.stringify(board.toOps())); }
  catch (_) { if (!saveFailed) { saveFailed = true; toast('Board is too big to keep on this iPad'); } }
}

function sendOp(o) {
  send(JSON.stringify(o.op === 'bg' ? { t: 'board', op: 'bg', bg: o.bg } : { t: 'ink', ...o }));
}

// One board change, everywhere at once: the model here, the snapshot, the Mac.
function inkOp(o) {
  board.apply(o);
  if (ready) sendOp(o);
  if (o.op !== 'pts' && o.op !== 'begin') saveSoon();   // an open stroke is saved when it ends
  if (o.op !== 'pts') bUI();
  wake();
}

// The Mac window asked for the whole board (it does when its page loads and when a new connection
// opens the board). The history collapses to exactly what the replay carries, here and there, so undo
// and redo stay identical on both sides. Between replays one connection keeps its full history.
function sendReplay() {
  if (!ready || !board) return;
  const ops = board.rebase();
  send('{"t":"ink","op":"reset"}');
  for (const o of ops) sendOp(o);
  saveSoon(); bUI(); wake();
}

// Ask the Mac to show the board window, only because the user tapped Board, the reopen hint, Copy or
// Save; never on connect. It answers with a state message, and with a replay request when this
// connection has not replayed into the window's current page load.
function requestOpen() {
  send('{"t":"board","op":"open"}');
}

// Copy and Save only go out once the window is open (the Mac reported open on this connection) and
// this page has answered a replay request on this connection; otherwise the Mac would export an
// empty board. If that is not true yet, open it and send the export as soon as it is, or give up
// after 8 s. A save then waits up to 60 s for the Mac (a first save can sit behind a macOS prompt).
let pendingExport = null, pendingSave = 0;
const exportReady = () => ready && stateOnConn && boardOpen === true && replayAnswered;

function exportBoard(what) {
  if (!ready) { toast('Not connected to the Mac'); return; }
  if (what === 'save' && pendingSave) return;   // one save at a time
  if (exportReady()) { sendExport(what); return; }
  clearTimeout(pendingExport && pendingExport.timer);
  pendingExport = { what, timer: setTimeout(() => { pendingExport = null; toast('The Board window did not open on the Mac'); }, 8000) };
  toast('Opening board…');
  requestOpen();
}

function checkExport() {
  if (!pendingExport || !exportReady()) return;
  clearTimeout(pendingExport.timer);
  const what = pendingExport.what;
  pendingExport = null;
  sendExport(what);
}

function sendExport(what) {
  send(`{"t":"board","op":"${what}"}`);
  if (what !== 'save') return;
  toast('Saving…', true);   // the done message replaces this
  pendingSave = setTimeout(() => { pendingSave = 0; toast('The Mac did not confirm the save'); }, 60000);
}

// The socket is gone: what the Mac window is doing now is unknown until the next hello brings a state.
function macLost() {
  closeWinMenu();   // its windows are the old connection's
  stateOnConn = false; replayAnswered = false; boardOpen = null;
  syncClosed();
  if (pendingExport) { clearTimeout(pendingExport.timer); pendingExport = null; }
  if (pendingSave) { clearTimeout(pendingSave); pendingSave = 0; toast('Connection lost during the save'); }
}

// Paste: the Mac stores the image on its clipboard and answers with its id and pixel size; the page
// then places it on the board like any other op. A tap while the Pencil is down never gets here (the
// palm rule on the toolbar swallows it).
function pasteImage() {
  if (!ready) { toast('Not connected to the Mac'); return; }
  send('{"t":"board","op":"paste"}');
}

// Centered, as large as fits in 80% of the board, keeping the picture's shape. x, y, w, h are board
// fractions (w of the width, h of the height), so the fit is worked in 16 by 9 board units.
const PASTE_FIT = 0.8;
function placeImage(m) {
  const pw = Number(m.w), ph = Number(m.h);
  if (typeof m.img !== 'string' || !(pw > 0) || !(ph > 0)) return;
  const s = Math.min(PASTE_FIT * 16 / pw, PASTE_FIT * 9 / ph);
  const w = pw * s / 16, h = ph * s / 9;
  inkOp({ op: 'image', id: board.nextId(), img: m.img, x: r5((1 - w) / 2), y: r5((1 - h) / 2), w: r5(w), h: r5(h) });
}

// ---------- Pencil -> ink ----------

const bPressure = (e) => (e.pressure > 0 ? Math.round(e.pressure * 1000) / 1000 : 0.5);   // no pressure: half

function boardDown(e, x, y) {
  if (!body.classList.contains('drawn')) body.classList.add('drawn');
  tip = { x: bx(x), y: by(y), on: true, c: inkColor() };
  lastTip = null;
  bPending = [];
  if (bTool === 'eraser') {
    bErasing = true; bErase.clear();
    eraseAt(x, y);
  } else {
    const id = board.nextId();
    bLive = id;
    inkOp({ op: 'begin', id, tool: bTool, color: inkColor(), size: bSize, pts: [[normX(x), normY(y), bPressure(e)]] });
  }
  wake(180);
}

function boardMove(e) {
  const list = hasCoalesced ? e.getCoalescedEvents() : null;
  const events = list && list.length ? list : [e];
  for (const ev of events) {
    const x = ev.clientX, y = ev.clientY;
    if (bErasing) eraseAt(x, y);
    else if (bLive !== null) {
      const X = normX(x), Y = normY(y), n = bPending.length;
      if (n ? bPending[n - 1][0] !== X || bPending[n - 1][1] !== Y : true) {
        bPending.push([X, Y, bPressure(ev)]);
        mote(bx(x), by(y));
      }
    }
  }
  tip.x = bx(e.clientX); tip.y = by(e.clientY);
  wake(180);
}

function boardUp() {
  boardLift();
  penId = -1; hoverStart = 0; hoverCount = 0;   // the mouse path never runs in Board mode
}

// Finish any open stroke or eraser drag: send what is pending, end the stroke, forget it.
function boardLift() {
  bFlush();
  bErasing = false;
  if (bLive !== null) { inkOp({ op: 'end', id: bLive }); bLive = null; }
  bPending = [];
  tip.on = false;
  wake(300);   // a last frame or two without the glow
  if (saveDeferred) saveSoon();
}

function eraseAt(x, y) {
  for (const id of board.hitTest(normX(x), normY(y), ERASE_R)) bErase.add(id);
}

// At most one erase op and one pts op per frame, split only if a frame ever carries a huge batch.
function bFlush() {
  if (bErase.size) {
    const ids = [...bErase];
    bErase.clear();
    for (let i = 0; i < ids.length; i += ERASE_CAP) inkOp({ op: 'erase', ids: ids.slice(i, i + ERASE_CAP) });
  }
  if (bLive !== null && bPending.length) {
    const pts = bPending;
    bPending = [];
    for (let i = 0; i < pts.length; i += PTS_CAP) inkOp({ op: 'pts', id: bLive, pts: pts.slice(i, i + PTS_CAP) });
  }
}

// ---------- Mac -> board messages ----------

function onBoard(m) {
  if (!board) return;
  if (m.op === 'replay') {
    sendReplay();
    replayAnswered = true;
    checkExport();
  } else if (m.op === 'state') {
    boardOpen = !!m.open;
    stateOnConn = true;
    syncClosed();
    checkExport();
  } else if (m.op === 'pasted') {
    if (m.ok) placeImage(m); else toast(m.why || 'Nothing to paste');
  } else if (m.op === 'done') {
    if (m.what === 'save' && pendingSave) { clearTimeout(pendingSave); pendingSave = 0; }
    if (m.what === 'copy') toast(m.ok ? 'Copied to Mac clipboard' : 'Copy failed');
    else toast(m.ok ? `Saved to Desktop: ${m.name || 'PencilPad Board.png'}` : 'Save failed');
  }
}

function syncClosed() {
  breopen.hidden = !(mode === 'board' && boardOpen === false);
}

let toastTimer = 0;
function toast(msg, sticky = false) {   // sticky: stays until the next toast replaces it
  toastEl.textContent = msg;
  toastEl.classList.add('on');
  clearTimeout(toastTimer);
  if (!sticky) toastTimer = setTimeout(() => toastEl.classList.remove('on'), 3200);
}

// ---------- Mode and board toolbar ----------

function setMode(m) {
  m = m === 'board' && core ? 'board' : 'mouse';
  if (m === mode) return;
  mode = m;
  closeWinMenu();
  store.set('mode', mode);
  if (mode === 'board') {
    setRight(false);   // a right-click armed for the mouse must not wait behind the board
    if (ready) requestOpen();
  }
  modeUI();
  fit();
}

function modeUI() {
  body.dataset.mode = mode;
  for (const b of modeBtns) b.setAttribute('aria-pressed', String(b.dataset.m === mode));
  hintTitle.textContent = mode === 'board' ? 'Draw on the shared Board' : 'Draw with Apple Pencil';
  hintText.textContent = mode === 'board'
    ? 'Strokes appear in the Board window on the Mac. Fingers only tap buttons.'
    : 'Touch lightly to aim, press to click. Fingers only tap buttons.';
  syncClosed();
  bUI();
}

function bUI() {
  if (!board) return;
  for (const b of toolBtns) b.classList.toggle('active', b.dataset.b === bTool);
  for (const b of colorBtns) b.classList.toggle('active', b.dataset.c === bColor);
  for (const b of sizeBtns) b.classList.toggle('active', +b.dataset.s === bSize);
  undoBtn.disabled = !board.canUndo();
  redoBtn.disabled = !board.canRedo();
  body.classList.toggle('inked', board.items.length > 0);
}

bar.addEventListener('click', (e) => {   // the palm rule above already swallowed any press made while the Pencil is down
  const b = e.target.closest('[data-m],[data-b],[data-c],[data-s]');
  if (!b) return;
  if (b.dataset.m) { setMode(b.dataset.m); return; }
  if (b.dataset.c) { bColor = b.dataset.c; store.set('bcolor', bColor); bUI(); return; }
  if (b.dataset.s) { bSize = +b.dataset.s; store.set('bsize', String(bSize)); bUI(); return; }
  switch (b.dataset.b) {
    case 'pen': case 'marker': case 'eraser':
      bTool = b.dataset.b; store.set('btool', bTool); bUI();
      break;
    case 'undo': inkOp({ op: 'undo' }); break;
    case 'redo': inkOp({ op: 'redo' }); break;
    case 'clear': inkOp({ op: 'clear' }); break;
    case 'bg': inkOp({ op: 'bg', bg: BGS[(BGS.indexOf(board.bg) + 1) % BGS.length] }); break;
    case 'copy': case 'save': exportBoard(b.dataset.b); break;
    case 'paste': pasteImage(); break;
  }
});

breopen.addEventListener('click', () => { if (ready) requestOpen(); });

// Keep the snapshot current if the page goes away before the save timer fires.
addEventListener('pagehide', () => { if (saveTimer || saveDeferred) saveNow(); });
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden' && (saveTimer || saveDeferred)) saveNow(); });

// The board survives reloads: restore the snapshot, closing any stroke the page was in the middle of.
try {
  const saved = board ? JSON.parse(store.get('board') || 'null') : null;
  if (Array.isArray(saved)) {
    for (const o of saved) board.apply(o);
    for (const s of board.items) board.apply({ op: 'end', id: s.id });
  }
} catch (_) { /* a damaged snapshot just starts an empty board */ }

// ---------- Start ----------

applyStyle();
applyAim();
modeUI();
fit();
connect();

import('./fx.js')
  .then((m) => { fx = m.start({ canvas: $('fx'), queue, ui }); fx.setStyle(style); })
  .catch((err) => { console.warn('PencilPad: effects unavailable, input still works.', err); body.classList.add('nofx'); });
