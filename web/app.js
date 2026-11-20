// PencilPad iPad page: Pencil input, the Mac socket, and the toolbar.
// Effects live in fx.js and load after this file, so input never waits on them.
// Wire protocol: see AGENTS.md at the repo root.

// board-core.js is a classic script loaded by index.html before this module (see its header). If it
// failed to load, Board is switched off and Mouse mode runs exactly as before.
const core = globalThis.PencilBoardCore || null;
const { createBoard, createView, renderInk, drawItem, fitNote, BGS, SHAPES } = core || {};

const WS_PORT = Number(location.port || 8710) + 1;   // the socket is always the page port + 1
const PING_MS = 500;
const DEAD_MS = 3000;     // no frame from the Mac for this long while connected: reconnect
const PAD = 14;          // gap between the active area and the screen edges
const GAP = 12;          // gap between the toolbar and the active area
const STYLES = ['line', 'blade', 'rainbow', 'off'];
const STYLE_NAMES = { line: 'Red line', blade: 'Silver blade', rainbow: 'Rainbow', off: 'Off' };

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
const ZOOM_MIN_W = 1 / 8;    // the most zoomed in: the region is this fraction of the target's width
const ZOOM_HOLD_MS = 600;    // press and hold Zoom this long to go back to the whole target
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
const zoomBtn = $('zoom'), hudLevel = $('hud-level'), miniEl = $('minimap'), miniBox = miniEl.firstElementChild;
const editorEl = $('editor'), edText = $('ed-text'), edBar = $('ed-bar');

const token = location.pathname.split('/').filter(Boolean)[0] || '';
const wsURL = `ws://${location.hostname}:${WS_PORT}/`;

// The active area in CSS px.
const area = { x: 0, y: 0, w: 1, h: 1 };
const ui = { rightArmed: false };

let ws = null, ready = false, halted = '';   // halted: '' | 'denied' | 'replaced'
let boardOpen = null;        // Board window state the Mac reported on this connection (it sends one after every hello); null = not heard yet
let stateOnConn = false;     // the Mac has reported the window state on this connection
let replayAnswered = false;  // this page has answered a replay request on this connection
let backoff = 500, retryTimer = 0, pingTimer = 0, lastRx = 0;
let screens = [], target = null;
const cam = { z: 1, cx: 0.5, cy: 0.5 };    // the zoom camera, see Zoom below
let region = { x: 0, y: 0, w: 1, h: 1 };   // the part of the target the active area shows, 0 to 1 of the target
let regionRaf = 0, regionSent = '';        // the animation frame that will send it, and what the Mac last heard
let regionSaved = '';                      // what localStorage holds for the current target, so it is only written when it changes
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
const normX = (x) => r5(clamp01((x - area.x) / area.w));   // 0 to 1 across the active area
const normY = (y) => r5(clamp01((y - area.y) / area.h));
// Mouse mode sends the Pencil as 0 to 1 of the target: the point in the active area, placed inside the zoomed region.
const toTargetX = (n) => r5(clamp01(region.x + n * region.w));
const toTargetY = (n) => r5(clamp01(region.y + n * region.h));
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

// What is left of the screen below the toolbar, inside the margins and safe areas.
function drawRect() {
  const W = innerWidth, H = innerHeight, cs = getComputedStyle(insetsEl);
  const it = parseFloat(cs.paddingTop) || 0, ir = parseFloat(cs.paddingRight) || 0;
  const ib = parseFloat(cs.paddingBottom) || 0, il = parseFloat(cs.paddingLeft) || 0;
  const top = Math.max(bar.getBoundingClientRect().bottom, it) + GAP;
  const left = il + PAD, right = W - ir - PAD, bottom = H - ib - PAD;
  return { left, top, aw: Math.max(1, right - left), ah: Math.max(1, bottom - top) };
}

function fit() {
  const { left, top, aw, ah } = drawRect();
  let w, h;
  if (mode === 'board') {
    h = aw / (16 / 9); w = aw;
    if (h > ah) { h = ah; w = ah * (16 / 9); }
    area.x = left + (aw - w) / 2; area.y = top + (ah - h) / 2;
  } else {
    // Mouse: the active area is the part of the target the zoom camera sees (see Zoom). Not zoomed, that is the
    // whole target letterboxed in the drawing area; zoomed in, it grows until it fills the drawing area.
    const v = clampCam(aw, ah), k = v.S;
    region = { x: Math.max(0, cam.cx - v.cw / 2), y: Math.max(0, cam.cy - v.ch / 2), w: Math.min(1, v.cw), h: Math.min(1, v.ch) };
    w = region.w * v.tw * k; h = region.h * v.th * k;
    area.x = left + aw / 2 + (region.x - cam.cx) * v.tw * k; area.y = top + ah / 2 + (region.y - cam.cy) * v.th * k;
  }
  area.w = w; area.h = h;
  const s = frame.style;
  s.left = area.x + 'px'; s.top = area.y + 'px'; s.width = w + 'px'; s.height = h + 'px';
  areaLabel.textContent = mode === 'board' ? 'Board · 16:9' : targetLabel();
  placeInk();
  placeMarks();
  placeProj();
  placeWinMenu();
  if (editing) { layoutEditor(); keepEditorVisible(); }   // rotation or a toolbar wrap moved the board: the editor follows it
  queueRegion();
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

function sendDown(X, Y, p) {   // X, Y: 0 to 1 of the target
  const b = ui.rightArmed ? 'right' : 'left';
  send(`{"t":"down","x":${X},"y":${Y},"p":${p},"tx":${tx},"ty":${ty},"b":"${b}"}`);
  stroke = true; lastX = X; lastY = Y;
  if (ui.rightArmed) setRight(false);   // only a real down uses up the right-click
}

// The tip crossed the threshold (or Aim is off): click here with the real pressure.
function pressAt(x, y, p) {
  const X = normX(x), Y = normY(y);
  aiming = false; aimPending = false;
  if (ready) sendDown(toTargetX(X), toTargetY(Y), p);
  lastSX = area.x + X * area.w; lastSY = area.y + Y * area.h;
  qv(DOWN, lastSX, lastSY, p, x, y, tiltMag());
}

// Below the threshold: the cursor follows, one hover per event.
function flushAim() {
  if (!aimPending) return;
  aimPending = false;
  const X = normX(aimX), Y = normY(aimY);
  if (ready && inArea(aimX, aimY)) send(`{"t":"hover","x":${toTargetX(X)},"y":${toTargetY(Y)}}`);   // outside the area only the reticle follows
  qv(AIM, area.x + X * area.w, area.y + Y * area.h, aimP, aimX, aimY, Math.min(1, aimP / aimAt()));
}

function onDown(e) {
  // fingers zooming: the Pencil does nothing to the Mac; while text is being typed the Pencil does not draw
  if (e.pointerType !== 'pen' || penId !== -1 || zoomPtrs.size || editing) return;
  const x = e.clientX, y = e.clientY;
  if (!inArea(x, y)) return;
  penId = e.pointerId; hoverStart = 0; hoverCount = 0;
  const p = pressure(e);
  notePressure(p);
  readTilt(e);
  e.preventDefault();
  try { surface.setPointerCapture(penId); } catch (_) {}
  if (mode === 'board') { boardDown(e, x, y); return; }   // Board: ink, never mouse
  if (annotOn) { if (annotReady) annotDown(e, x, y); return; }   // Annotate: ink over the window, never mouse (and not while matching up after a connect)
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
    lastX = toTargetX(X); lastY = toTargetY(Y);
    send(`{"t":"move","x":${lastX},"y":${lastY},"p":${p},"tx":${tx},"ty":${ty}}`);
  }
  lastSX = area.x + X * area.w; lastSY = area.y + Y * area.h;
  qv(MOVE, lastSX, lastSY, p, x, y, tiltMag());
}

function onMove(e) {
  if (e.pointerType !== 'pen') return;
  if (e.pointerId === penId) {
    if (e.buttons === 0) { onUp(e); return; }   // lifted without a pointerup: release now
    if (mode === 'board') { boardMove(e); return; }   // Board: ink locally, no mouse messages
    if (annotOn) { if (annotLive !== null) annotMove(e); return; }
    const list = hasCoalesced ? e.getCoalescedEvents() : null;
    if (list && list.length) for (let i = 0; i < list.length; i++) contactPoint(list[i]);
    else contactPoint(e);
    flushAim();
    return;
  }
  if (penId !== -1 || e.buttons !== 0) return;
  const x = e.clientX, y = e.clientY;
  if (ready && mode === 'mouse' && !annotOn && !zoomPtrs.size && inArea(x, y)) send(`{"t":"hover","x":${toTargetX(normX(x))},"y":${toTargetY(normY(y))}}`);
  qv(HOVER, x, y, 0, x, y, 0);
  noteHover();
}

function onUp(e) {
  if (e.pointerId !== penId) return;
  if (mode === 'board') { boardUp(e); return; }
  if (annotOn || annotLive !== null) { annotLift(e); penId = -1; hoverStart = 0; hoverCount = 0; return; }
  if (e.type === 'pointerup' || e.type === 'pointermove') { lastX = toTargetX(normX(e.clientX)); lastY = toTargetY(normY(e.clientY)); }
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
  const inking = annotLive !== null;
  annotLift();
  if (stroke) send(`{"t":"up","x":${lastX},"y":${lastY}}`);
  if (penId !== -1 && mode !== 'board' && !inking) qv(UP, lastSX, lastSY, 0, lastSX, lastSY, 0);
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
const notButton = (e) => !(e.target instanceof Element && e.target.closest('button, textarea'));
// While text is being typed, a touch within SCRIBBLE_PX of the text box is let through too, so handwriting that
// starts beside the box still reaches Scribble.
const SCRIBBLE_PX = 40;
const nearEditor = (e) => {
  if (!editing) return false;
  const r = edText.getBoundingClientRect();
  return [...e.touches, ...e.changedTouches].some((t) =>
    t.clientX >= r.left - SCRIBBLE_PX && t.clientX <= r.right + SCRIBBLE_PX && t.clientY >= r.top - SCRIBBLE_PX && t.clientY <= r.bottom + SCRIBBLE_PX);
};
const block = (e) => { if (notButton(e) && !nearEditor(e)) e.preventDefault(); };
document.addEventListener('touchstart', block, { passive: false });
document.addEventListener('touchmove', block, { passive: false });
for (const t of ['gesturestart', 'gesturechange', 'gestureend']) document.addEventListener(t, (e) => e.preventDefault(), { passive: false });
document.addEventListener('dblclick', (e) => e.preventDefault(), { passive: false });
document.addEventListener('contextmenu', (e) => e.preventDefault());
document.addEventListener('selectstart', (e) => {   // no selecting anywhere except in the text editor
  const t = e.target instanceof Element ? e.target : e.target && e.target.parentElement;
  if (!(t && t.closest('textarea'))) e.preventDefault();
});

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
  s.binaryType = 'arraybuffer';
  ws = s;
  s.onopen = () => {
    lastRx = performance.now();
    s.send(JSON.stringify({ t: 'hello', token, v: 2 }));   // v 2: this page numbers what it wants to see (rev) and the Mac tags its frames with it
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
  if (typeof data !== 'string') { onFrameBytes(data); return; }   // a projection frame
  let m;
  try { m = JSON.parse(data); } catch (_) { return; }
  switch (m.t) {
    case 'show':
      onShow(m);
      break;
    case 'hello':
      ready = true; backoff = 500; regionSent = ''; showKey = '';
      annotReady = false; bumpRev();   // the Mac's marks are on their way; so is a picture, asked for again below
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
    case 'annot':
      onAnnot(m);
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
  const changed = !target || regionKey(target) !== regionKey(t);
  const kindChanged = !target || showKind(target) !== showKind(t);
  // Every window choice has its own number, even one that picked the same window again. A new one: the marks and the picture
  // belong to what was there before and go, and nothing is drawn until the Mac has sent this choice's marks.
  const newChoice = typeof t.gen === 'number' && t.gen !== (target && target.gen);
  const hadMarks = !!marks && marks.items.length > 0;
  if (newChoice) { annotDrop(); annotReady = false; clearProj(); bumpRev(); if (showKey !== '' && showKey !== 'off') showKey = 'stale'; }   // the picture of what was there goes at once and is asked for again (fit below); a stream the Mac holds stays known, so a Show-off target still stops it
  target = t;
  if (t.w > 0 && t.h > 0) store.set('aspect', String(t.w / t.h));
  if (changed) { loadRegion(t); regionSent = ''; }   // that target's own zoom, and the Mac hears it once
  if (kindChanged) { showOn = showPref(showKind(t)); if (!showOn) clearProj(); updateShowUI(); }   // a window starts showing by itself
  markTarget();
  if (newChoice && hadMarks) toast('Marks cleared: the target changed');
  annotUI();
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

// ---------- Zoom ----------

// The drawing area is a window onto the target, seen by a camera. cam.z is how far in it looks, with 1 the whole
// target fitted inside the drawing area (letterboxed, as before); cam.cx and cam.cy are the target point (0 to 1)
// at the middle of the drawing area. The active area is the part of the target the camera sees, so zooming in
// is continuous: the letterbox shrinks away, then the active area fills the iPad and the region has the iPad's
// shape, inside the target. The region is sent to the Mac and kept per target.

function clampCam(aw, ah) {
  const tw = target && target.w > 0 ? target.w : cachedAspect(), th = target && target.h > 0 ? target.h : 1;
  const base = Math.min(aw / tw, ah / th);                          // iPad px per target point, whole target fitted
  const zMax = Math.max(1, aw / (ZOOM_MIN_W * tw * base));          // the region is never narrower than ZOOM_MIN_W of the target
  cam.z = Math.min(Math.max(cam.z, 1), zMax);
  const S = cam.z * base, cw = aw / (S * tw), ch = ah / (S * th);   // the camera's size, as fractions of the target
  cam.cx = cw >= 1 ? 0.5 : Math.min(Math.max(cam.cx, cw / 2), 1 - cw / 2);
  cam.cy = ch >= 1 ? 0.5 : Math.min(Math.max(cam.cy, ch / 2), 1 - ch / 2);
  return { tw, th, base, zMax, S, cw, ch };
}

// Each screen keeps its own region; every window target is just "window", so those are kept per app.
const regionKey = (t) => (t.id === 'window' && t.app ? 'window:' + t.app : t.id);

// That target's saved region becomes the camera (whole target when there is none).
function loadRegion(t) {
  cam.z = 1; cam.cx = cam.cy = 0.5;
  const raw = store.get('region.' + regionKey(t)) || '';
  regionSaved = regionKey(t) + '=' + raw;
  const v = raw.split(',').map(Number);
  if (v.length !== 4 || !v.every(Number.isFinite)) return;
  const [x, y, w, h] = v, { aw, ah } = drawRect();
  const tw = t.w > 0 ? t.w : 1, th = t.h > 0 ? t.h : 1, base = Math.min(aw / tw, ah / th);
  // A region that spans the whole of one axis says nothing about the camera on it; the other axis does.
  if (w > 0 && w < 0.999) cam.z = (aw / (base * tw)) / w;
  else if (h > 0 && h < 0.999) cam.z = (ah / (base * th)) / h;
  cam.cx = x + w / 2; cam.cy = y + h / 2;
}

// One region message per animation frame, and only when it changed.
function queueRegion() { if (!regionRaf) regionRaf = requestAnimationFrame(flushRegion); }
function flushRegion() {
  regionRaf = 0;
  updateZoomUI();
  if (mode !== 'mouse' || !target) { syncShow(); return; }
  const v = [region.x, region.y, region.w, region.h].map(r5), s = v.join(',');
  const saved = regionKey(target) + '=' + s;
  if (saved !== regionSaved && !zoomPtrs.size) { regionSaved = saved; store.set('region.' + regionKey(target), s); }   // once, when the fingers lift
  if (ready && s !== regionSent) {
    regionSent = s;
    bumpRev();   // the old picture may stay until a frame made for this part arrives; none made for the old part is drawn
    send(`{"t":"region","x":${v[0]},"y":${v[1]},"w":${v[2]},"h":${v[3]},"rev":${projRev}}`);
  }
  syncShow();
}

// The level, and a tiny map of where the region sits in the target.
function updateZoomUI() {
  const zoomed = cam.z > 1.005, level = `${cam.z.toFixed(1)}×`;
  body.classList.toggle('zoomed', zoomed);
  hudLevel.textContent = level;
  if (!zoomed) return;
  const tw = target && target.w > 0 ? target.w : cachedAspect(), th = target && target.h > 0 ? target.h : 1;
  const k = Math.min(64 / tw, 40 / th);   // fits a 64 x 40 box
  miniEl.style.width = Math.round(tw * k) + 'px'; miniEl.style.height = Math.round(th * k) + 'px';
  const s = miniBox.style;
  s.left = region.x * 100 + '%'; s.top = region.y * 100 + '%'; s.width = region.w * 100 + '%'; s.height = region.h * 100 + '%';
}

// Tapping Zoom arms ONE finger gesture on the drawing surface (fingers otherwise only press buttons): two fingers
// pinch around their midpoint and drag, one finger drags. When the fingers lift the gesture ends and Zoom disarms.
let zoomArmed = false;
const zoomPtrs = new Map();   // finger pointer id -> { x, y }, while a zoom gesture is in progress
let zoomFrom = null;          // the camera and the fingers when the number of fingers last changed
let zoomHold = 0, zoomHeld = false, zoomFitRaf = 0;

function armZoom(on) {
  zoomArmed = on;
  zoomBtn.classList.toggle('armed', on);
  zoomBtn.setAttribute('aria-pressed', String(on));
  body.classList.toggle('zoomarmed', on);
  if (!on) { zoomPtrs.clear(); zoomFrom = null; body.classList.remove('zooming'); }
}

function zoomFingers() {
  const pts = [...zoomPtrs.values()];
  const mx = pts.reduce((a, p) => a + p.x, 0) / pts.length, my = pts.reduce((a, p) => a + p.y, 0) / pts.length;
  return { mx, my, d: pts.length > 1 ? Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y) : 0 };
}

function zoomRebase() { zoomFrom = { z: cam.z, cx: cam.cx, cy: cam.cy, ...zoomFingers() }; }

// The target point that was under the fingers' midpoint when the gesture began stays under it.
function zoomMove() {
  if (!zoomFrom || !zoomPtrs.size) return;
  const f = zoomFingers(), { left, top, aw, ah } = drawRect(), v = clampCam(aw, ah);   // v.base, v.zMax, tw, th
  const z = Math.min(Math.max(zoomFrom.z * (zoomFrom.d > 0 && f.d > 0 ? f.d / zoomFrom.d : 1), 1), v.zMax);
  const S0 = zoomFrom.z * v.base, S1 = z * v.base, mx = left + aw / 2, my = top + ah / 2;
  const ux = zoomFrom.cx + (zoomFrom.mx - mx) / (v.tw * S0), uy = zoomFrom.cy + (zoomFrom.my - my) / (v.th * S0);
  cam.z = z; cam.cx = ux - (f.mx - mx) / (v.tw * S1); cam.cy = uy - (f.my - my) / (v.th * S1);
  if (!zoomFitRaf) zoomFitRaf = requestAnimationFrame(() => { zoomFitRaf = 0; fit(); });
}

// A resting palm is not a zoom finger. Touch radii say so (a contact wider than PALM_PX across); pointer and touch
// events can come in either order, so the two are matched by where they landed.
const palms = [];   // recent palm contacts { x, y, at }
const nearPalm = (x, y) => {
  const now = performance.now();
  while (palms.length && now - palms[0].at > 300) palms.shift();
  return palms.some((p) => Math.hypot(p.x - x, p.y - y) < 6);
};
surface.addEventListener('touchstart', (e) => {
  for (const t of e.changedTouches) {
    if (!touchPalm(t)) continue;
    palms.push({ x: t.clientX, y: t.clientY, at: performance.now() });
    for (const [id, p] of zoomPtrs) if (Math.hypot(p.x - t.clientX, p.y - t.clientY) < 6) zoomPtrs.delete(id);   // its pointerdown came first
  }
  if (zoomPtrs.size) zoomRebase();
  else { zoomFrom = null; body.classList.remove('zooming'); }
}, { passive: true });

surface.addEventListener('pointerdown', (e) => {
  if (!zoomArmed || e.pointerType !== 'touch' || penId !== -1 || mode !== 'mouse' || zoomPtrs.size >= 2) return;
  if (palmSized(e) || nearPalm(e.clientX, e.clientY)) return;
  zoomPtrs.set(e.pointerId, { x: e.clientX, y: e.clientY });
  try { surface.setPointerCapture(e.pointerId); } catch (_) {}
  body.classList.add('zooming');
  zoomRebase();
});
surface.addEventListener('pointermove', (e) => {
  const p = zoomPtrs.get(e.pointerId);
  if (!p) return;
  p.x = e.clientX; p.y = e.clientY;
  zoomMove();
});
function zoomUp(e) {
  if (!zoomPtrs.delete(e.pointerId)) return;
  if (zoomPtrs.size) { zoomRebase(); return; }
  cancelAnimationFrame(zoomFitRaf); zoomFitRaf = 0;
  armZoom(false);   // the fingers are up: the gesture is over
  fit();
}
for (const t of ['pointerup', 'pointercancel', 'lostpointercapture']) surface.addEventListener(t, zoomUp);

function resetZoom() { cam.z = 1; cam.cx = cam.cy = 0.5; fit(); }

// A tap arms or disarms; a press held for ZOOM_HOLD_MS shows the whole target again. A palm or a Pencil stroke
// is ignored, as on every toolbar button.
zoomBtn.addEventListener('pointerdown', () => {
  zoomHeld = false;
  clearTimeout(zoomHold);
  zoomHold = setTimeout(() => {
    if (penId !== -1 || pressDuringStroke) return;
    zoomHeld = true; armZoom(false); resetZoom();
  }, ZOOM_HOLD_MS);
});
for (const t of ['pointerup', 'pointercancel', 'pointerleave']) zoomBtn.addEventListener(t, () => clearTimeout(zoomHold));
zoomBtn.addEventListener('click', () => {
  if (zoomHeld) { zoomHeld = false; return; }   // that press already did its job
  armZoom(!zoomArmed);
});

// ---------- Show (projection) ----------

// The Mac streams what is under the active area (the window, or the zoomed part of a screen) as JPEG frames. They are
// drawn on a canvas exactly covering the active area, over the page (the effects are stopped while it shows), and each is acknowledged once drawn, so the Mac never has more than two in flight.
const PROJ_MAX = 2048;   // the longest side asked for, in device pixels
const proj = $('proj'), projCtx = proj.getContext('2d'), showBtn = $('show'), hudFps = $('hud-fps');
let showOn = false;                       // what the page wants
let showKey = '';                         // what the Mac was last told, so a change is sent once
let projLive = false;                     // frames are arriving
let projLast = null;                      // the last frame, redrawn when the layer is resized
let projChain = Promise.resolve();        // frames are drawn in the order they arrive
let projCount = 0, projTimer = 0, projDrawnAt = 0;
const PROJ_PEN_MS = 100;   // while the Pencil is down a picture is drawn at most this often (about 10 a second)

const showKind = (t) => (t && t.id === 'window' ? 'window' : 'screen');
// Windows start on, screens off until tapped; each kind keeps its last choice.
const showPref = (kind) => { const v = store.get('show.' + kind); return v == null ? kind === 'window' : v === '1'; };

// The active area in device pixels, longest side capped.
function projSize() {
  const dpr = window.devicePixelRatio || 1, k = Math.min(1, PROJ_MAX / Math.max(area.w * dpr, area.h * dpr, 1));
  return [Math.max(1, Math.round(area.w * dpr * k)), Math.max(1, Math.round(area.h * dpr * k))];
}

function placeProj() {
  const s = proj.style;
  s.left = area.x + 'px'; s.top = area.y + 'px'; s.width = area.w + 'px'; s.height = area.h + 'px';
  const [w, h] = projSize();
  if (proj.width !== w || proj.height !== h) {
    proj.width = w; proj.height = h;   // resizing clears the canvas: put the last frame back until the next one comes
    if (projLast) projCtx.drawImage(projLast, 0, 0, w, h);
  }
}

// A page nobody can see must not be fed a picture: hidden (another tab, a locked iPad) or on its way out, Show is off
// as far as the Mac is concerned; it goes back to the person's choice the moment the page is visible again.
let pageGone = false;
const pageHidden = () => document.hidden || pageGone;
document.addEventListener('visibilitychange', () => syncShow());
addEventListener('pagehide', () => { pageGone = true; syncShow(); });
addEventListener('pageshow', () => { pageGone = false; syncShow(); });

// Tells the Mac to start, resize or stop: on a resize, a target change or a region change, once each.
function syncShow() {
  const want = showOn && mode === 'mouse' && ready && target && !pageHidden();
  let key = 'off';
  if (want) {
    const [w, h] = projSize();
    key = `${w}x${h} ${regionKey(target)} ${target.w}x${target.h} ${[region.x, region.y, region.w, region.h].map(r5)}`;
  }
  if (key === showKey || (key === 'off' && showKey === '')) return;
  showKey = key;
  if (want) {
    const [w, h] = projSize();
    bumpRev();   // a new stream, a resize, another window or another part: whatever arrives for the old one is not drawn
    send(`{"t":"show","on":true,"w":${w},"h":${h},"rev":${projRev}}`);
  } else { send('{"t":"show","on":false}'); }
}

function updateShowUI() {
  showBtn.classList.toggle('on', showOn);
  showBtn.setAttribute('aria-pressed', String(showOn));
  const live = showOn && projLive && mode === 'mouse';
  body.classList.toggle('projecting', live);
  quietUI();
}

function clearProj() {
  projCtx.clearRect(0, 0, proj.width, proj.height);
  if (projLast) { projLast.close(); projLast = null; }
  projLive = false; projCount = 0;
  clearInterval(projTimer); projTimer = 0;
  hudFps.textContent = '';
  updateShowUI();
}

function setShow(on, remember) {
  showOn = on;
  if (remember && target) store.set('show.' + showKind(target), on ? '1' : '0');
  if (!on) clearProj();
  updateShowUI();
  syncShow();
}

showBtn.addEventListener('click', () => setShow(!showOn, true));

// Which picture a frame is of travels with it. The page numbers what it wants to see (`rev`) and bumps it whenever that changes:
// a window chosen, a region change, Show on or resized, the page visible again, a reconnect. Every `show` and `region` carries
// the current one, the Mac tags each frame with the one whose window and crop it was made under, and the page draws a frame only
// if its tag is the current one, checked again after the decode, right before painting. So a picture of another window, or of
// a part the iPad has moved away from, is never drawn behind the marks. After a region change the old picture may stay until the
// first matching frame arrives (the accepted limit, up to about 200 ms); after a window choice the picture is cleared at once.
let projRev = 0;
const bumpRev = () => { projRev = (projRev + 1) % 2147483648; };   // stays inside what the Mac accepts: a whole number, 0 to 2^31
const revTag = () => projRev & 0xffff;                             // frames carry it modulo 65536

// One binary frame: a 4-byte big-endian number, a 2-byte tag, then the JPEG. Acknowledged once drawn or dropped, always, so
// the Mac's two-frame limit never waits on a picture this page threw away.
function onFrameBytes(buf) {
  if (!(buf instanceof ArrayBuffer) || buf.byteLength < 7) return;
  const dv = new DataView(buf), n = dv.getUint32(0), tag = dv.getUint16(4), blob = new Blob([new Uint8Array(buf, 6)], { type: 'image/jpeg' });
  projChain = projChain.then(() => drawFrame(n, blob, tag));
}

async function drawFrame(n, blob, tag) {
  try {
    // The Pencil's own work comes first: while it is down the next picture waits its turn, and the ack waits with it,
    // so the Mac holds back (its two-frame limit) and the rate falls by itself; it returns to full the moment the Pencil lifts.
    if (tag === revTag() && penId !== -1) {
      const wait = PROJ_PEN_MS - (performance.now() - projDrawnAt);
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    }
    if (showOn && tag === revTag() && mode === 'mouse' && !pageHidden()) {
      const bmp = await createImageBitmap(blob);
      if (showOn && tag === revTag()) {
        projCtx.drawImage(bmp, 0, 0, proj.width, proj.height);
        projDrawnAt = performance.now();
        if (projLast) projLast.close();
        projLast = bmp;
        projCount++;
        if (!projTimer) projTimer = setInterval(() => { hudFps.textContent = `${projCount} fps`; projCount = 0; }, 1000);
      } else bmp.close();
    }
  } catch (_) {}
  send(`{"t":"frame","ack":${n}}`);   // the Mac holds the next frames back until it hears this
}

// The Mac's answer: frames are coming, or why not (the stream is already stopped).
function onShow(m) {
  if (m.ok) { projLive = true; updateShowUI(); return; }
  showOn = false; showKey = 'off';
  clearProj();
  toast(m.why || 'The Mac could not show it');
}

// ---------- Buttons ----------

// A toolbar press that starts while the Pencil is down is a palm or a slip: swallow it before any button sees it.
// The same guard covers a palm-sized contact or a second finger: Touch radii are half the contact's size.
let pressDuringStroke = false;
const palmSized = (e) => e.pointerType === 'touch' && Math.max(e.width, e.height) > PALM_PX;
const touchPalm = (t) => 2 * Math.max(t.radiusX || 0, t.radiusY || 0) > PALM_PX;
const palmTouch = (e) => e.touches.length > 1 || [...e.changedTouches].some(touchPalm);
for (const el of [bar, winMenu, edBar]) {
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

// No page effects on the Board, while Annotate is on, or while Show is on: the loop is stopped, the canvas and the Effects button hidden.
function quietUI() {
  const q = mode === 'board' || showOn || annotOn;
  body.classList.toggle('quiet', q);
  if (fx) fx.setQuiet(q);
}

let style = STYLES.includes(store.get('style')) ? store.get('style') : 'line';
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

$('clear').addEventListener('click', () => { if (fx && !body.classList.contains('quiet')) fx.clear(); });

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
const H_OVER_W = 9 / 16;    // the board is 16:9
const MIN_SHAPE = 0.006;    // a shape drag shorter than this (board widths) is a tap, not a shape
const SHAPE_NAMES = { line: 'Line', arrow: 'Arrow', rect: 'Rectangle', ellipse: 'Ellipse' };
const SHAPE_ICONS = {
  line: '<path d="M5 19 19 5"/>',
  arrow: '<path d="M5 19 19 5"/><path d="M10 5h9v9"/>',
  rect: '<rect x="4.5" y="6.5" width="15" height="11" rx="1.5"/>',
  ellipse: '<ellipse cx="12" cy="12" rx="8" ry="6"/>',
};
const TEXT_SIZES = { 0.0028: 0.032, 0.0048: 0.048, 0.0078: 0.075 };   // pen size -> text size, a fraction of the board height
const NOTE_H = 0.16, NOTE_W = Math.round(NOTE_H * H_OVER_W * 1e5) / 1e5;   // a sticky note is 0.16 of the board height each way

const ink = $('ink'), inkCtx = ink.getContext('2d');
const breopen = $('breopen'), toastEl = $('toast'), hintEl = $('hint');
const hintTitle = hintEl.querySelector('strong'), hintText = hintEl.querySelector('span');
const modeBtns = [...bar.querySelectorAll('[data-m]')];
const toolBtns = [...bar.querySelectorAll('[data-b="pen"],[data-b="marker"],[data-b="eraser"],[data-b="shape"],[data-b="text"],[data-b="note"]')];
const shapeBtn = bar.querySelector('[data-b="shape"]');
const colorBtns = [...bar.querySelectorAll('[data-c]')], sizeBtns = [...bar.querySelectorAll('[data-s]')];
const undoBtn = bar.querySelector('[data-b="undo"]'), redoBtn = bar.querySelector('[data-b="redo"]');

let mode = core && store.get('mode') === 'board' ? 'board' : 'mouse';
if (!core) body.classList.add('noboard');
try { localStorage.removeItem('pencilpad.boardopen'); } catch (_) {}   // an earlier build remembered the window state; the Mac is the truth now
let bTool = ['pen', 'marker', 'eraser', 'shape', 'text', 'note'].includes(store.get('btool')) ? store.get('btool') : 'pen';
let bShape = core && SHAPES.includes(store.get('bshape')) ? store.get('bshape') : 'line';
let bColor = COLORS.includes(store.get('bcolor')) ? store.get('bcolor') : '#ffffff';
let bSize = SIZES.some(([, v]) => v === Number(store.get('bsize'))) ? Number(store.get('bsize')) : 0.0048;

const board = core ? createBoard() : null, view = core ? createView() : null;
if (board) board.onImage = () => wake();   // a pasted image finished loading: draw it
let bLive = null, bErasing = false;   // open stroke id, eraser drag
let shapeDrag = null;                 // a shape being dragged: its two corners (board fractions)
let placing = null;                   // the Pencil is down with the Text or Note tool: where it touched
let editing = null;                   // the text or note being typed: what it is and where it goes
let bPending = [], bErase = new Set();   // points and stroke ids waiting for this frame's flush

const lightBg = () => board.bg === 'white' || board.bg === 'grid';
// White ink on the white board draws black and black ink on the dark board draws white.
const inkColor = () => (lightBg() ? (bColor === '#ffffff' ? '#000000' : bColor) : (bColor === '#000000' ? '#ffffff' : bColor));

// ---------- Ink canvas (the board, over the effects canvas) ----------

let inkRaf = 0, dirtyUntil = 0;
let tip = { x: 0, y: 0, on: false, c: '#ffffff' };   // the eraser ring follows it; Board mode has no other effects

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
  if (!inkRaf && performance.now() < dirtyUntil) inkRaf = requestAnimationFrame(inkFrame);
}

function drawInk() {
  const w = ink.width, h = ink.height;
  if (!w || !h || mode !== 'board') return;
  view.draw(board, inkCtx, w, h);   // the board itself: identical to the Mac window
  if (shapeDrag) drawItem(inkCtx, w, h, { kind: 'shape', shape: bShape, color: inkColor(), size: bSize, ...shapeDrag }, board.bg);   // the shape being dragged, drawn exactly as it will land
  if (tip.on && bTool === 'eraser') {
    const k = w / area.w, light = lightBg();
    inkCtx.save();
    inkCtx.strokeStyle = light ? 'rgba(20,24,40,0.55)' : 'rgba(255,255,255,0.6)';
    inkCtx.lineWidth = Math.max(1, k * 1.2);
    inkCtx.beginPath(); inkCtx.arc(tip.x, tip.y, ERASE_R * w, 0, 6.2832); inkCtx.stroke();
    inkCtx.restore();
  }
}

// Pointer position in ink bitmap pixels.
const bx = (clientX) => (clientX - area.x) / area.w * ink.width;
const by = (clientY) => (clientY - area.y) / area.h * ink.height;

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
  regionSent = ''; showKey = '';
  bumpRev();   // whatever the old connection was still sending is not for the next one
  clearProj();
  stateOnConn = false; replayAnswered = false; boardOpen = null;
  syncClosed();
  if (pendingExport) { clearTimeout(pendingExport.timer); pendingExport = null; }
  if (pendingSave) { clearTimeout(pendingSave); pendingSave = 0; toast('Connection lost during the save'); }
  annotReady = false;   // nothing is drawn, cleared or saved until the next hello has matched the marks up
  if (annotSaving) { clearTimeout(annotSaving.timer); annotSaving = null; toast('Connection lost during the save'); }
  annotUI();
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
  bPending = [];
  if (bTool === 'eraser') {
    bErasing = true; bErase.clear();
    eraseAt(x, y);
  } else if (bTool === 'shape') {
    const X = normX(x), Y = normY(y);
    shapeDrag = { x0: X, y0: Y, x1: X, y1: Y };
  } else if (bTool === 'text' || bTool === 'note') {
    placing = { x: normX(x), y: normY(y), sx: x, sy: y, moved: false };   // placed when the Pencil lifts, if it was a tap
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
    else if (shapeDrag) { shapeDrag.x1 = normX(x); shapeDrag.y1 = normY(y); }
    else if (placing) { if (Math.hypot(x - placing.sx, y - placing.sy) > 40) placing.moved = true; }
    else if (bLive !== null) {
      const X = normX(x), Y = normY(y), n = bPending.length;
      if (n ? bPending[n - 1][0] !== X || bPending[n - 1][1] !== Y : true) {
        bPending.push([X, Y, bPressure(ev)]);
      }
    }
  }
  tip.x = bx(e.clientX); tip.y = by(e.clientY);
  wake(180);
}

// The Pencil lifted. A tap with the Text or Note tool opens the editor where it touched.
function boardUp(e) {
  const tapped = placing && !placing.moved && e && (e.type === 'pointerup' || e.type === 'pointermove') ? placing : null;
  boardLift();
  penId = -1; hoverStart = 0; hoverCount = 0;   // the mouse path never runs in Board mode
  if (tapped) openEditor(bTool, tapped.x, tapped.y);
}

// Finish any open stroke, shape or eraser drag: send what is pending, end the stroke, forget it.
function boardLift() {
  bFlush();
  bErasing = false;
  if (bLive !== null) { inkOp({ op: 'end', id: bLive }); bLive = null; }
  if (shapeDrag) {
    const d = shapeDrag;
    shapeDrag = null;
    if (Math.hypot(d.x1 - d.x0, (d.y1 - d.y0) * H_OVER_W) >= MIN_SHAPE) {
      inkOp({ op: 'shape', id: board.nextId(), kind: bShape, x0: d.x0, y0: d.y0, x1: d.x1, y1: d.y1, color: inkColor(), size: bSize });
    }
  }
  placing = null;
  bPending = [];
  tip.on = false;
  wake(300);
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

// ---------- Text and sticky note editor ----------

// A real textarea laid over the board where the Pencil tapped, so iPad Scribble handwriting and the
// keyboard both work. Done puts the text on the board as one op; empty text cancels. While it is open the
// Pencil does not draw (onDown), and a tap on any toolbar button finishes it first.
const noteColor = () => (bColor === '#ffffff' ? '#ffd60a' : bColor);   // a sticky note is yellow unless a color is picked
const tintOf = (hex) => {   // the same soft tint the board draws a note in
  const n = parseInt(hex.slice(1), 16), t = (v) => Math.round(v + (255 - v) * 0.7);
  return `rgb(${t((n >> 16) & 255)},${t((n >> 8) & 255)},${t(n & 255)})`;
};

function openEditor(kind, X, Y) {
  closeEditor(true);   // finish an earlier one first
  if (kind === 'note') {
    const w = NOTE_W, h = NOTE_H;   // centered on the tap, kept on the board
    editing = { kind, x: r5(Math.min(1 - w, Math.max(0, X - w / 2))), y: r5(Math.min(1 - h, Math.max(0, Y - h / 2))), w, h, color: noteColor() };
  } else {
    editing = { kind, x: X, y: Y, size: TEXT_SIZES[bSize] || 0.048, color: inkColor() };
  }
  edText.value = '';
  edText.maxLength = kind === 'note' ? 600 : 2000;
  layoutEditor();
  editorEl.hidden = false;
  keepEditorVisible();
  edText.focus();
}

function layoutEditor() {
  if (!editing) return;
  const e = editing, left = area.x + e.x * area.w, top = area.y + e.y * area.h, st = edText.style;
  editorEl.style.left = left + 'px';
  editorEl.style.top = top + 'px';
  if (e.kind === 'note') {
    const w = e.w * area.w, h = e.h * area.h, pad = Math.min(w, h) * 0.1, fs = h * 0.22;
    st.width = w + 'px'; st.height = Math.max(h, 3 * fs * 1.2 + 2 * pad) + 'px'; st.padding = pad + 'px';   // never less than three lines
    st.background = tintOf(e.color); st.color = '#2a2a2c';
    st.fontSize = fs + 'px'; st.lineHeight = '1.2'; st.fontWeight = '500';
    st.boxShadow = '0 0 0 2px rgb(var(--accent) / .85), 0 6px 18px rgb(0 0 0 / .4)'; st.borderRadius = Math.min(w, h) * 0.05 + 'px';
  } else {
    const fs = e.size * area.h;
    st.width = Math.max(200, Math.min(area.w * 0.5, area.x + area.w - left)) + 'px';
    st.padding = '0';
    st.background = 'transparent'; st.color = e.color;
    st.fontSize = fs + 'px'; st.lineHeight = '1.25'; st.fontWeight = '600';
    st.boxShadow = '0 0 0 2px rgb(var(--accent) / .85), 0 0 18px rgb(var(--accent) / .3)'; st.borderRadius = '3px';
    st.height = Math.max(3 * fs * 1.25, edText.scrollHeight) + 'px';   // never less than three lines
  }
}

// The on-screen keyboard can cover the lower part of the page: lift the editor above it.
function keepEditorVisible() {
  if (!editing) return;
  const vv = window.visualViewport, bottom = vv ? vv.offsetTop + vv.height : innerHeight;
  const r = edText.getBoundingClientRect();
  const up = r.bottom + 56 > bottom && r.top > 64;   // the Done row goes above the box when there is no room below it
  editorEl.classList.toggle('up', up);
  const over = r.bottom + (up ? 0 : 56) - bottom;
  if (over > 0) editorEl.style.top = Math.max(bar.getBoundingClientRect().bottom + 6, r.top - over) + 'px';
}
if (window.visualViewport) window.visualViewport.addEventListener('resize', keepEditorVisible);

edText.addEventListener('input', () => {
  if (editing && editing.kind === 'text') { edText.style.height = 'auto'; edText.style.height = Math.max(3 * editing.size * area.h * 1.25, edText.scrollHeight) + 'px'; }
});
edText.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') { e.preventDefault(); closeEditor(false); }
  else if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); closeEditor(true); }
});
$('ed-done').addEventListener('click', () => closeEditor(true));
$('ed-cancel').addEventListener('click', () => closeEditor(false));

// The on-screen keyboard can leave a full-screen web app shifted when it goes away; put the page back at the top.
// (The keyboard takes a moment to leave, so it is done again shortly after.)
function scrollHome() {
  const home = () => { window.scrollTo(0, 0); document.documentElement.scrollTop = 0; document.body.scrollTop = 0; };
  home();
  setTimeout(home, 120);
  setTimeout(home, 400);
}

function closeEditor(commit) {
  if (!editing) return;
  const e = editing, text = edText.value.replace(/\s+$/, '');
  editing = null;
  editorEl.hidden = true;
  editorEl.classList.remove('up');
  edText.blur();
  edText.value = '';
  scrollHome();
  if (!commit || !text.trim()) return;   // empty text cancels
  if (e.kind === 'note') {   // the font size and line breaks are decided here, once, and travel in the op
    const L = fitNote(text, e.w, e.h);
    inkOp({ op: 'note', id: board.nextId(), x: e.x, y: e.y, w: e.w, h: e.h, text, color: e.color, fs: Math.round(L.fs * 1e5) / 1e5, lines: L.lines });
  }
  else inkOp({ op: 'text', id: board.nextId(), x: e.x, y: e.y, text, color: e.color, size: e.size });
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
  closeEditor(true);
  mode = m;
  closeWinMenu();
  armZoom(false);
  if (mode === 'board') { clearProj(); annotOff(); }   // fit() below tells the Mac to stop; the marks stay on the Mac
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
  quietUI();
  for (const b of modeBtns) b.setAttribute('aria-pressed', String(b.dataset.m === mode));
  syncClosed();
  bUI();
  hintUI();
  annotUI();
}

function bUI() {
  if (!board) return;
  for (const b of toolBtns) b.classList.toggle('active', b.dataset.b === bTool);
  for (const b of colorBtns) b.classList.toggle('active', b.dataset.c === bColor);
  for (const b of sizeBtns) b.classList.toggle('active', +b.dataset.s === bSize);
  if (shapeBtn.dataset.k !== bShape) {   // the Shape button shows the kind that is current
    shapeBtn.dataset.k = bShape;
    shapeBtn.innerHTML = `<svg viewBox="0 0 24 24">${SHAPE_ICONS[bShape]}</svg>`;
    shapeBtn.setAttribute('aria-label', `Shape: ${SHAPE_NAMES[bShape]}`);
    shapeBtn.title = `Shape: ${SHAPE_NAMES[bShape]}. Drag to draw it, tap again to change kind`;
  }
  undoBtn.disabled = !board.canUndo();
  redoBtn.disabled = !board.canRedo();
  body.classList.toggle('inked', board.items.length > 0);
}

bar.addEventListener('click', (e) => {   // the palm rule above already swallowed any press made while the Pencil is down
  const b = e.target.closest('[data-m],[data-b],[data-c],[data-s]');
  if (!b) return;
  closeEditor(b.dataset.b !== 'undo' && b.dataset.b !== 'redo');   // a tap on the toolbar finishes the text being typed; Undo and Redo drop it
  if (b.dataset.m) { setMode(b.dataset.m); return; }
  if (b.dataset.c) { bColor = b.dataset.c; store.set('bcolor', bColor); bUI(); return; }
  if (b.dataset.s) { bSize = +b.dataset.s; store.set('bsize', String(bSize)); bUI(); return; }
  switch (b.dataset.b) {
    case 'pen': case 'marker': case 'eraser':
      bTool = b.dataset.b; store.set('btool', bTool); bUI();
      break;
    case 'shape':   // the first tap picks the tool, each tap after that picks the next kind
      if (bTool === 'shape') { bShape = SHAPES[(SHAPES.indexOf(bShape) + 1) % SHAPES.length]; store.set('bshape', bShape); }
      bTool = 'shape'; store.set('btool', bTool); bUI();
      break;
    case 'text': case 'note':
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

// ---------- Annotate ----------

// Mouse mode, window target. With Annotate on the Pencil draws instead of driving the mouse: no hover, down, move or up
// is sent. The marks are drawn here (over the projection) and on the Mac (a click-through overlay over the window, so
// the room sees them), both by board-core.js. x, y are 0 to 1 of the window, so the marks stay right under any zoom and
// when the window is resized.
//
// The Mac owns the marks; this page keeps no copy of its own to hand back. A stroke is drawn here at once for feel and sent;
// if the Mac refuses it (`drop`) it is taken back out. After every hello, window choice and Clear the Mac sends all of its marks
// (a `reset`, the marks, then `synced` with their count) and this page shows exactly that. Until `synced` has arrived nothing
// is drawn, cleared or saved (annotReady). Every message carries the number of the target choice the page is showing.

const ANNOT_COLOR = '#ff453a', ANNOT_SIZE = 0.0065;   // one strong red, a medium width (a fraction of the window's width)
const marksCv = $('marks'), marksCtx = marksCv.getContext('2d');
const annotBtn = $('annot'), annotSaveBtn = $('annot-save'), annotClearBtn = $('annot-clear');
const marks = core ? createBoard() : null;
const marksView = core ? core.createInkView() : null;   // finished marks are kept drawn; a repaint adds only what is new
let annotOn = false;
let annotReady = false;    // the Mac's marks for the current target choice have fully arrived
let annotLive = null;      // the open stroke's id while the Pencil is down
let annotPending = [];     // points of the open stroke not yet sent
let annotLast = null;      // the last point of the open stroke, [x, y, p]
let marksRaf = 0;
let annotSaving = null;    // { rid, timer } of the save the page is waiting on
let annotRid = 0;          // numbers saves, so a late answer can only be taken for the save it answers

const annotGen = () => (target && typeof target.gen === 'number' ? target.gen : null);   // the target choice being shown
const annotWindow = () => !!marks && mode === 'mouse' && !!target && showKind(target) === 'window';
const annotShown = () => !!marks && marks.items.length > 0;   // with no marks there is no bitmap, whether Annotate is on or not

function annotUI() {
  if (!marks) return;
  const win = annotWindow(), has = marks.items.length > 0;
  annotBtn.hidden = !win;
  annotBtn.classList.toggle('on', annotOn);
  annotBtn.setAttribute('aria-pressed', String(annotOn));
  annotSaveBtn.hidden = annotClearBtn.hidden = !(win && (annotOn || has));
  annotSaveBtn.disabled = annotClearBtn.disabled = !annotReady;   // not while the Mac's marks are still on their way
  body.classList.toggle('annotating', annotOn && win);
  body.classList.toggle('marked', annotShown());   // the picture then moves with the marks, not gliding behind them
  hintUI();
}

// The first-use hint says what the Pencil does now.
function hintUI() {
  if (mode === 'board') {
    hintTitle.textContent = 'Draw on the shared Board';
    hintText.textContent = 'Strokes appear in the Board window on the Mac. Fingers only tap buttons.';
  } else if (annotOn && annotWindow()) {
    hintTitle.textContent = 'Mark up the window';
    hintText.textContent = 'Draw to mark it in red; the cursor stays put. Tap Annotate again to click and scroll. Fingers only tap buttons.';
  } else {
    hintTitle.textContent = 'Draw with Apple Pencil';
    hintText.textContent = 'Touch lightly to aim, press to click. Fingers only tap buttons.';
  }
}

// Annotate's buttons can wrap the toolbar onto a second row: the drawing area starts below whatever height it has.
let barH = 0;
if (typeof ResizeObserver !== 'undefined') {
  new ResizeObserver(() => { const h = bar.getBoundingClientRect().height; if (h !== barH) { barH = h; fit(); } }).observe(bar);
}

// The marks over the active area. The active area is the part of the window the iPad shows (the region), so the whole
// window is 1 / region.w of its width, and the bitmap is offset to where the region begins. With no marks there is no
// bitmap at all (and no cache of finished ink), Annotate on or off.
function placeMarks() {
  if (!marks) return;
  const s = marksCv.style;
  if (mode !== 'mouse' || !annotShown()) {
    s.width = s.height = '0px';
    if (marksCv.width !== 0) { marksCv.width = marksCv.height = 0; marksView.release(); }   // sizing to zero lets the backing go
    return;
  }
  const dpr = Math.min(3, window.devicePixelRatio || 1);
  s.left = area.x + 'px'; s.top = area.y + 'px'; s.width = area.w + 'px'; s.height = area.h + 'px';
  const w = Math.max(1, Math.round(area.w * dpr)), h = Math.max(1, Math.round(area.h * dpr));
  if (marksCv.width !== w || marksCv.height !== h) { marksCv.width = w; marksCv.height = h; }
  drawMarks();
}

function drawMarks() {
  const w = marksCv.width, h = marksCv.height;
  if (!w || !h) return;
  if (mode !== 'mouse') { marksCtx.clearRect(0, 0, w, h); return; }
  const W = w / region.w, H = h / region.h;   // the whole window, in bitmap pixels
  marksView.draw(marks, marksCtx, w, h, W, H, region.x * W, region.y * H);
}

function marksWake() {
  if (!marksRaf) marksRaf = requestAnimationFrame(() => { marksRaf = 0; if (annotShown() || marksCv.width) placeMarksIfNeeded(); });
}
// A mark was added or removed: the bitmap appears with the first one and goes with the last.
function placeMarksIfNeeded() { if (!!marksCv.width !== (mode === 'mouse' && annotShown())) placeMarks(); else drawMarks(); }

// One op: here, and to the Mac (begin, pts and end draw there; the Mac keeps them).
function annotApply(o) {
  marks.apply(o);
  send(JSON.stringify({ t: 'annot', gen: annotGen(), ...o }));
  marksWake();
  if (o.op !== 'pts') annotUI();
}

function annotDown(e, x, y) {
  const first = [toTargetX(normX(x)), toTargetY(normY(y)), bPressure(e)];
  if (!Number.isFinite(first[0]) || !Number.isFinite(first[1]) || annotGen() === null) return;   // no point to draw: no mark, on either side
  if (!body.classList.contains('drawn')) body.classList.add('drawn');
  annotPending = [];
  annotLive = marks.nextId();
  annotLast = first;
  annotApply({ op: 'begin', id: annotLive, tool: 'pen', color: ANNOT_COLOR, size: ANNOT_SIZE, pts: [first] });
}

// A point is kept only if it moved. Marks are drawn here at once; the Mac hears them in batches (see annotFlush).
function annotPoint(X, Y, p) {
  if (!Number.isFinite(X) || !Number.isFinite(Y)) return null;
  if (annotLast && annotLast[0] === X && annotLast[1] === Y) return null;
  annotLast = [X, Y, p];
  return annotLast;
}

const ANNOT_BATCH_MS = 40;   // the Mac is sent the new points of a stroke at most this often
let annotFlushTimer = 0;

function annotMove(e) {
  const list = hasCoalesced ? e.getCoalescedEvents() : null;
  const fresh = [];
  for (const ev of list && list.length ? list : [e]) {
    const pt = annotPoint(toTargetX(normX(ev.clientX)), toTargetY(normY(ev.clientY)), bPressure(ev));
    if (pt) fresh.push(pt);
  }
  annotGrow(fresh);
}

function annotGrow(fresh) {
  if (!fresh.length) return;
  marks.apply({ op: 'pts', id: annotLive, pts: fresh });
  annotPending.push(...fresh);
  marksWake();
  if (!annotFlushTimer) annotFlushTimer = setTimeout(annotFlush, ANNOT_BATCH_MS);
}

// Sends the points gathered since the last batch (already drawn here).
function annotFlush() {
  clearTimeout(annotFlushTimer); annotFlushTimer = 0;
  if (annotLive === null || !annotPending.length) return;
  const pts = annotPending;
  annotPending = [];
  for (let i = 0; i < pts.length; i += PTS_CAP) send(JSON.stringify({ t: 'annot', gen: annotGen(), op: 'pts', id: annotLive, pts: pts.slice(i, i + PTS_CAP) }));
}

// The Pencil lifted, or the page is letting go of it: finish the open stroke. A genuine lift (it has a position) draws
// to where the Pencil came off, when that is not where the last move was.
function annotLift(e) {
  if (annotLive === null) return;
  if (e && e.type === 'pointerup') {
    const pt = annotPoint(toTargetX(normX(e.clientX)), toTargetY(normY(e.clientY)), annotLast ? annotLast[2] : 0.5);
    if (pt) annotGrow([pt]);
  }
  annotFlush();
  annotApply({ op: 'end', id: annotLive });
  annotLive = null;
  annotLast = null;
}

// The open stroke is no more (the Mac refused it or ended it): nothing more of it is sent.
function annotForget(id) {
  if (annotLive !== id) return;
  clearTimeout(annotFlushTimer); annotFlushTimer = 0;
  annotLive = null; annotPending = []; annotLast = null;
}

function annotOff() {
  annotLift();
  annotOn = false;
  quietUI();
  annotUI();
  placeMarks();
}

// Every mark gone from this page. (The Mac is told by whoever calls this, or already knows.)
function annotWipe() {
  annotLift();
  marks.apply({ op: 'reset' });
  annotUI();
  placeMarks();
}

// Another window or a screen became the target: no marks, Annotate off.
function annotDrop() {
  if (!marks || (!annotOn && !marks.items.length)) return;
  annotOff();
  annotWipe();
}

annotBtn.addEventListener('click', () => {
  if (annotOn) { annotOff(); return; }
  if (!ready || !annotReady || !annotWindow()) return;
  setRight(false);   // a right-click armed for the mouse must not wait behind the marks
  annotOn = true;
  quietUI();
  send(JSON.stringify({ t: 'annot', op: 'on', gen: annotGen() }));   // the Mac says if this window cannot be marked
  annotUI();
  placeMarks();
});

annotClearBtn.addEventListener('click', () => {
  if (!annotReady) return;
  annotWipe();
  annotReady = false;   // the Mac answers with its (now empty) marks
  send(JSON.stringify({ t: 'annot', op: 'clear', gen: annotGen() }));
  annotUI();
});

annotSaveBtn.addEventListener('click', () => {
  if (!ready || !annotReady) { toast('Not connected to the Mac'); return; }
  if (annotSaving) return;   // one save at a time
  annotLift();
  const rid = ++annotRid;
  send(JSON.stringify({ t: 'annot', op: 'save', rid, gen: annotGen() }));
  toast('Saving…', true);   // the done message replaces this
  annotSaving = { rid, timer: setTimeout(() => { annotSaving = null; toast('The Mac did not confirm the save'); }, 60000) };
});

// A stroke ended where the Mac's cap is: the page's copy is cut to the Mac's points.
function annotCut(id, len) {
  const ops = marks.toOps().filter((o) => o.op !== 'bg');
  marks.apply({ op: 'reset' });
  let kept = 0;
  for (const o of ops) {
    if (o.id === id && (o.op === 'begin' || o.op === 'pts')) {
      const room = len - kept;
      if (room <= 0) continue;
      o.pts = o.pts.slice(0, room);
      kept += o.pts.length;
    }
    marks.apply(o);
  }
  marks.apply({ op: 'end', id });
}

function onAnnot(m) {
  if (!marks) return;
  if (m.op === 'done') {   // an answer belongs to the save it names; a late one for an earlier save is not news
    if (!annotSaving || annotSaving.rid !== m.rid) return;
    clearTimeout(annotSaving.timer); annotSaving = null;
    toast(m.ok ? `Saved to Desktop: ${m.name || 'PencilPad Annotation.png'}` : (m.why || 'Save failed'));
    return;
  }
  if (m.gen !== annotGen()) return;   // about a target choice this page is not showing
  switch (m.op) {
    case 'reset':   // the Mac's marks follow, whole, ended by `synced`
      annotWipe();
      annotReady = false;
      annotUI();
      break;
    case 'begin': case 'pts': case 'end':   // only the Mac's own marks come this way, and only before `synced`
      if (annotReady) break;
      marks.apply(m);
      marksWake();
      if (m.op === 'begin') annotUI();
      break;
    case 'synced':
      if (marks.items.length !== m.n) {   // not what the Mac says it holds: start the match-up again rather than guess
        toast('Marks out of step with the Mac; reconnecting');
        try { ws && ws.close(); } catch (_) {}
        break;
      }
      annotReady = true;
      annotUI();
      break;
    case 'drop':   // the Mac took no part in this stroke: it comes back out
      if (m.kind === 'dup') break;   // it already holds a stroke with this id, the one the page drew first: that one stays
      if (typeof m.id !== 'number') break;   // a stale clear or on: no stroke is named
      annotForget(m.id);
      marks.apply({ op: 'erase', ids: [m.id] });
      marksWake();
      annotUI();
      if (m.kind === 'cap') toast(m.why || 'Too many marks');
      else if (m.kind === 'window') { toast(m.why || 'This window can\'t be marked'); annotOff(); }
      break;
    case 'cut':   // a stroke ended at the Mac's cap
      annotForget(m.id);
      annotCut(m.id, Number(m.len) || 1);
      marksWake();
      toast(m.why || 'Too many points; the mark ended here');
      break;
    case 'refused':
      toast(m.why || 'This window can\'t be marked');
      annotOff();
      break;
  }
}

// ---------- Start ----------

applyStyle();
applyAim();
modeUI();
fit();
connect();

import('./fx.js')
  .then((m) => { fx = m.start({ canvas: $('fx'), queue }); fx.setQuiet(body.classList.contains('quiet')); fx.setStyle(style); })
  .catch((err) => { console.warn('PencilPad: effects unavailable, input still works.', err); body.classList.add('nofx'); });
