// PencilPad board: the shared ink model and renderer.
//
// The iPad page and the Mac Board window both apply the same ink ops from the wire protocol (see
// AGENTS.md) through createBoard().apply(), and both draw with the same functions here, so the two
// boards match stroke for stroke.
//
// This is a CLASSIC script on purpose (no import/export). The Mac window loads web/board.html from a
// file:// URL in a WKWebView, which refuses ES module imports from file:// (the module never runs);
// classic scripts load fine. The iPad page loads this file with a plain <script> tag before app.js.
// Everything is published as one global: window.PencilBoardCore.

(() => {
'use strict';

const BGS = ['dark', 'white', 'grid', 'dots'];
const IMG_ID = /^[0-9a-f]{12}$/;   // a pasted image's id: the name of its file on the Mac
const H_OVER_W = 9 / 16;    // the board is 16:9; y is normalized to the board height
const PTS_CHUNK = 512;      // most points in one begin/pts op from toOps() (about 13 KB on the wire)
const TAU = Math.PI * 2;
const SHAPES = ['line', 'arrow', 'rect', 'ellipse'];
const TEXT_MAX = 2000, NOTE_MAX = 600;   // most characters in one text label or sticky note
// Text is a clean system sans. Sizes below are fractions of the board HEIGHT, so a label looks the same
// at every resolution; layout (line widths, wrapping, fit) is worked out in board-height units from one
// reference measurement, so the iPad, the Mac window and the 4K export all break lines the same way.
const FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif';
const TEXT_WEIGHT = 600, NOTE_WEIGHT = 500;
const LINE_H = 1.25, NOTE_LINE_H = 1.2;
// Where each line's baseline sits below the top of its line box, in font sizes. Text is placed by its
// alphabetic baseline, which every engine defines the same way (the 'top' baseline does not), so the iPad
// and the Mac window put the same letters in the same place. The values put the text where the editor's
// textarea shows it.
const TEXT_BASE = 0.98, NOTE_BASE = 0.956;
const hexColor = (c, d) => (typeof c === 'string' && /^#[0-9a-f]{6}$/i.test(c) ? c.toLowerCase() : d);

const r5 = (v) => Math.round(v * 1e5) / 1e5;
const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const num = (v, d) => (typeof v === 'number' && isFinite(v) ? v : d);
const isLight = (bg) => bg === 'white' || bg === 'grid';

function sanitizePts(pts) {
  if (!Array.isArray(pts)) return [];
  const out = [];
  for (const p of pts) {
    if (!Array.isArray(p) || typeof p[0] !== 'number' || typeof p[1] !== 'number') continue;
    out.push([r5(clamp01(p[0])), r5(clamp01(p[1])), r5(clamp01(num(p[2], 0.5)))]);
  }
  return out;
}

// ---------- Images ----------

// A board keeps its decoded pasted images by id (see createBoard). The URL is relative on purpose: it
// resolves to /<token>/img/<id> on the iPad page and to pencilpad-board://board/img/<id> in the Mac
// window, and both serve the Mac's image store. An entry settles once: a failed load stays failed,
// so a missing file can never loop.
function loadImage(cache, k) {   // cache: id -> { el, state: 'loading' | 'ready' | 'failed', done: Promise }
  let e = cache.get(k);
  if (e) return e;
  const el = new Image();
  e = { el, state: 'loading', done: null };
  e.done = new Promise((resolve) => {
    const settle = (state) => { e.state = state; resolve(); };
    el.onload = () => (el.decode ? el.decode() : Promise.resolve()).catch(() => {}).then(() => settle('ready'));
    el.onerror = () => settle('failed');
  });
  cache.set(k, e);
  el.src = 'img/' + k;
  return e;
}

// Every image that has decoded, under everything else.
function drawImages(ctx, w, h, board) {
  ctx.save();
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  for (const it of board.items) {
    if (it.kind !== 'image') continue;
    const e = board.image(it.img);
    if (e && e.state === 'ready') ctx.drawImage(e.el, it.x * w, it.y * h, it.w * w, it.h * h);
  }
  ctx.restore();
}

// ---------- Text layout ----------

let measureCtx = null;
const widths = new Map();   // `${weight}|${string}` -> width in ems
function ems(str, weight) {   // width of str when the font size is 1
  const key = weight + '|' + str;
  let v = widths.get(key);
  if (v === undefined) {
    if (!measureCtx) measureCtx = document.createElement('canvas').getContext('2d');
    measureCtx.font = `${weight} 100px ${FONT}`;
    v = measureCtx.measureText(str).width / 100;
    if (widths.size > 20000) widths.clear();
    widths.set(key, v);
  }
  return v;
}

// A text label's lines and size in board-height units (1 = the board's height). Wraps on \n only.
function textBox(it) {
  if (!it.box) {
    const lines = it.text.split('\n');
    let w = 0;
    for (const l of lines) w = Math.max(w, ems(l, TEXT_WEIGHT) * it.size);
    it.box = { lines, w, h: lines.length * it.size * LINE_H };
  }
  return it.box;
}

// Words that fit maxW, one paragraph per \n; a word wider than a line is cut by characters.
function wrapLines(text, fs, maxW) {
  const out = [];
  const fits = (str) => ems(str, NOTE_WEIGHT) * fs <= maxW;
  for (const para of text.split('\n')) {
    let line = '';
    for (const word of para.split(' ')) {
      const joined = line ? line + ' ' + word : word;
      if (fits(joined)) { line = joined; continue; }
      if (line) { out.push(line); line = ''; }
      if (fits(word)) { line = word; continue; }
      let chunk = '';
      for (const ch of word) {
        if (!chunk || fits(chunk + ch)) chunk += ch; else { out.push(chunk); chunk = ch; }
      }
      line = chunk;
    }
    out.push(line);
  }
  return out;
}

// A sticky note's wrapped lines and font size: the largest size (down to a floor) whose text fits
// inside the card's padding. Board-height units again. w is the card's width as a fraction of the board
// width, h its height as a fraction of the board height.
function fitNote(text, w, h) {
  const cw = w * 16 / 9, ch = h, pad = Math.min(cw, ch) * 0.1;
  const iw = cw - 2 * pad, ih = ch - 2 * pad, floor = ch * 0.07;
  let fs = ch * 0.24, lines;
  for (;;) {
    lines = wrapLines(text, fs, iw);
    if (lines.length * fs * NOTE_LINE_H <= ih || fs <= floor) break;
    fs = Math.max(floor, fs * 0.92);
  }
  return { lines, fs, pad };
}

// What a note draws with. The iPad measures the text once and sends the result in the note op (`fs` and
// `lines`), and every board draws from those given values, so no engine ever re-decides where a line
// breaks. An op without them (an older one) is measured here instead.
function noteLayout(it) {
  if (!it.lay) {
    const pad = Math.min(it.w * 16 / 9, it.h) * 0.1;
    it.lay = it.given ? { lines: it.given.lines, fs: it.given.fs, pad } : fitNote(it.text, it.w, it.h);
  }
  return it.lay;
}

// The line breaks and font size an op carries for a sticky note, or null if it does not carry usable ones.
function givenLayout(m) {
  if (!Array.isArray(m.lines) || typeof m.fs !== 'number' || !isFinite(m.fs) || m.fs <= 0) return null;
  return { fs: r5(Math.min(0.2, Math.max(0.005, m.fs))), lines: m.lines.slice(0, 80).map((l) => (typeof l === 'string' ? l.slice(0, 300) : '')) };
}

// ---------- Hit tests (the eraser) ----------
// All in board-width units: x as is, y scaled by 9/16, so distances are true.

function distToSeg(px, py, ax, ay, bx, by) {
  const dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
  const t = len2 ? Math.min(1, Math.max(0, ((px - ax) * dx + (py - ay) * dy) / len2)) : 0;
  return Math.hypot(ax + t * dx - px, ay + t * dy - py);
}

function distToBox(px, py, x0, y0, w, h) {
  return Math.hypot(Math.max(x0 - px, 0, px - (x0 + w)), Math.max(y0 - py, 0, py - (y0 + h)));
}

// A shape is hit by its outline (a rectangle's four sides, an ellipse's rim), not its inside.
function hitShape(s, x, ay, r) {
  const reach = r + s.size / 2 + 0.001;
  const ax = s.x0, bx = s.x1, cy0 = s.y0 * H_OVER_W, cy1 = s.y1 * H_OVER_W;
  if (s.shape === 'line' || s.shape === 'arrow') return distToSeg(x, ay, ax, cy0, bx, cy1) <= reach;
  if (s.shape === 'rect') {
    return distToSeg(x, ay, ax, cy0, bx, cy0) <= reach || distToSeg(x, ay, bx, cy0, bx, cy1) <= reach ||
           distToSeg(x, ay, bx, cy1, ax, cy1) <= reach || distToSeg(x, ay, ax, cy1, ax, cy0) <= reach;
  }
  const cx = (ax + bx) / 2, cy = (cy0 + cy1) / 2, rx = Math.abs(bx - ax) / 2, ry = Math.abs(cy1 - cy0) / 2;
  let px = cx + rx, py = cy;
  for (let i = 1; i <= 48; i++) {
    const a = (i / 48) * TAU, qx = cx + rx * Math.cos(a), qy = cy + ry * Math.sin(a);
    if (distToSeg(x, ay, px, py, qx, qy) <= reach) return true;
    px = qx; py = qy;
  }
  return false;
}

// ---------- Model ----------

function createBoard() {
  const items = [];            // everything on the board in order: strokes, shapes, text, notes and images
  const byId = new Map();
  const images = new Map();    // decoded pasted images by id (see loadImage)
  const undoStack = [], redoStack = [];
  let bg = 'dark', idSeq = 0;  // ids only ever grow, so an undone id is never reused
  let gen = 0;                 // bumps whenever anything already drawn changes (see createView)

  const addItem = (s) => { items.push(s); byId.set(s.id, s); };

  // Remove by id, remembering the original positions so undo can put them back.
  const removeIds = (ids) => {
    const set = new Set(ids), gone = [];
    items.forEach((s, i) => { if (set.has(s.id)) gone.push({ s, i }); });
    for (let k = gone.length - 1; k >= 0; k--) { items.splice(gone[k].i, 1); byId.delete(gone[k].s.id); }
    return gone;
  };
  const insertItems = (gone) => {
    for (const { s, i } of gone) {
      if (byId.has(s.id)) continue;
      items.splice(Math.min(i, items.length), 0, s);
      byId.set(s.id, s);
    }
  };
  const pushStep = (step) => { undoStack.push(step); redoStack.length = 0; };
  // A finished item (shape, text, note): onto the board, one undo step, and the board redraws.
  const addAndPush = (n) => {
    addItem(n);
    if (n.id >= idSeq) idSeq = n.id + 1;
    pushStep({ k: 'add', s: n });
    gen++;
  };

  // Let go of decoded images that are neither on the board nor in its undo or redo history, so a long
  // session does not hold dozens of decoded 4K pictures. Runs on reset and clear. (The picture stays on
  // the Mac; a dropped one that comes back is simply loaded again.)
  const pruneImages = () => {
    const keep = new Set();
    const note = (s) => { if (s.kind === 'image') keep.add(s.img); };
    items.forEach(note);
    for (const st of undoStack) { if (st.k === 'add') note(st.s); else st.items.forEach((it) => note(it.s)); }
    for (const st of redoStack) { if (st.k === 'add') note(st.s); else st.items.forEach((it) => note(it.s)); }
    for (const k of [...images.keys()]) if (!keep.has(k)) images.delete(k);
  };

  const stepDo = (st) => {
    if (st.k === 'add') { if (!byId.has(st.s.id)) addItem(st.s); }
    else removeIds(st.items.map((it) => it.s.id));
  };
  const stepUndo = (st) => {
    if (st.k === 'add') {
      const s = byId.get(st.s.id);
      if (s) { items.splice(items.indexOf(s), 1); byId.delete(s.id); }
    } else insertItems(st.items);
  };

  // One ink or bg message, exactly as it crossed the wire. Anything else is ignored.
  function apply(m) {
    if (!m || typeof m !== 'object') return;
    switch (m.op) {
      case 'reset':
        items.length = 0; byId.clear(); bg = 'dark'; idSeq = 0;
        undoStack.length = 0; redoStack.length = 0; gen++;
        if (!m.keepImages) pruneImages();   // (rebase keeps them: it puts the same ones straight back, then prunes)
        break;
      case 'bg':
        if (BGS.includes(m.bg) && m.bg !== bg) { bg = m.bg; gen++; }
        break;
      case 'begin': {
        const pts = sanitizePts(m.pts);
        const s = byId.get(m.id);
        if (s) {   // a repeated begin just continues the stroke (an id that is not a stroke is left alone)
          if (s.kind !== 'stroke') break;
          s.pts.push(...pts);
          if (s.ended) gen++;
          break;
        }
        const n = {
          kind: 'stroke', id: m.id,
          tool: m.tool === 'marker' ? 'marker' : 'pen',
          color: typeof m.color === 'string' && /^#[0-9a-f]{6}$/i.test(m.color) ? m.color.toLowerCase() : '#ffffff',
          size: Math.min(0.05, Math.max(0.0005, num(m.size, 0.0048))),
          pts, ended: false,
        };
        addItem(n);
        if (Number.isFinite(n.id) && n.id >= idSeq) idSeq = n.id + 1;
        pushStep({ k: 'add', s: n });   // the whole stroke is one undo step
        break;
      }
      case 'image': {   // a pasted picture, placed by its top-left corner; one undo step
        if (!Number.isFinite(m.id) || byId.has(m.id) || typeof m.img !== 'string' || !IMG_ID.test(m.img)) break;
        const n = {
          kind: 'image', id: m.id, img: m.img,
          x: r5(clamp01(num(m.x, 0))), y: r5(clamp01(num(m.y, 0))),
          w: r5(Math.min(1, Math.max(0.001, num(m.w, 0.8)))), h: r5(Math.min(1, Math.max(0.001, num(m.h, 0.8)))),
          ended: true,
        };
        addItem(n);
        if (n.id >= idSeq) idSeq = n.id + 1;
        pushStep({ k: 'add', s: n });
        gen++;
        loadImage(images, n.img).done.then(() => { gen++; if (board.onImage) board.onImage(); });
        break;
      }
      case 'shape': {   // a line, arrow, rectangle or ellipse from corner (x0, y0) to corner (x1, y1); one undo step
        if (!Number.isFinite(m.id) || byId.has(m.id) || !SHAPES.includes(m.kind)) break;
        addAndPush({
          kind: 'shape', shape: m.kind, id: m.id,
          x0: r5(clamp01(num(m.x0, 0))), y0: r5(clamp01(num(m.y0, 0))), x1: r5(clamp01(num(m.x1, 0))), y1: r5(clamp01(num(m.y1, 0))),
          color: hexColor(m.color, '#ffffff'), size: Math.min(0.05, Math.max(0.0005, num(m.size, 0.0048))), ended: true,
        });
        break;
      }
      case 'text': {   // a label, top-left at (x, y), size = font size as a fraction of the board height
        if (!Number.isFinite(m.id) || byId.has(m.id) || typeof m.text !== 'string' || !m.text.trim()) break;
        addAndPush({
          kind: 'text', id: m.id, x: r5(clamp01(num(m.x, 0))), y: r5(clamp01(num(m.y, 0))),
          text: m.text.slice(0, TEXT_MAX), color: hexColor(m.color, '#ffffff'), size: r5(Math.min(0.2, Math.max(0.01, num(m.size, 0.048)))), ended: true,
        });
        break;
      }
      case 'note': {   // a sticky note, top-left at (x, y); w of the board width, h of its height
        if (!Number.isFinite(m.id) || byId.has(m.id) || typeof m.text !== 'string' || !m.text.trim()) break;
        addAndPush({
          kind: 'note', id: m.id, x: r5(clamp01(num(m.x, 0))), y: r5(clamp01(num(m.y, 0))),
          w: r5(Math.min(1, Math.max(0.02, num(m.w, 0.09)))), h: r5(Math.min(1, Math.max(0.03, num(m.h, 0.16)))),
          text: m.text.slice(0, NOTE_MAX), color: hexColor(m.color, '#ffd60a'), ended: true,
          given: givenLayout(m),
        });
        break;
      }
      case 'pts': {   // points for a stroke that was never begun are ignored
        const s = byId.get(m.id);
        const pts = sanitizePts(m.pts);
        if (s && s.kind === 'stroke' && pts.length) {
          s.pts.push(...pts);
          if (s.ended) gen++;
        }
        break;
      }
      case 'end': {
        const s = byId.get(m.id);
        if (s) s.ended = true;
        break;
      }
      case 'erase': {
        const ids = (Array.isArray(m.ids) ? m.ids : []).filter((id) => byId.has(id));
        if (!ids.length) break;
        pushStep({ k: 'erase', items: removeIds(ids) });
        gen++;
        break;
      }
      case 'clear': {
        if (!items.length) break;
        pushStep({ k: 'erase', items: items.map((s, i) => ({ s, i })) });
        items.length = 0; byId.clear(); gen++;
        pruneImages();
        break;
      }
      case 'undo': {
        const st = undoStack.pop();
        if (!st) break;
        stepUndo(st); redoStack.push(st); gen++;
        break;
      }
      case 'redo': {
        const st = redoStack.pop();
        if (!st) break;
        stepDo(st); undoStack.push(st); gen++;
        break;
      }
    }
  }

  // Ops that rebuild the current board: bg, then every live item. A stroke that is still open
  // (Pencil down) is replayed without its end so it can keep growing.
  function toOps() {
    const ops = [{ op: 'bg', bg }];
    for (const s of items) {
      if (s.kind === 'image') {
        ops.push({ op: 'image', id: s.id, img: s.img, x: s.x, y: s.y, w: s.w, h: s.h });
        continue;
      }
      if (s.kind === 'shape') {
        ops.push({ op: 'shape', id: s.id, kind: s.shape, x0: s.x0, y0: s.y0, x1: s.x1, y1: s.y1, color: s.color, size: s.size });
        continue;
      }
      if (s.kind === 'text') {
        ops.push({ op: 'text', id: s.id, x: s.x, y: s.y, text: s.text, color: s.color, size: s.size });
        continue;
      }
      if (s.kind === 'note') {
        const L = noteLayout(s);   // a replay carries the layout the note was made with
        ops.push({ op: 'note', id: s.id, x: s.x, y: s.y, w: s.w, h: s.h, text: s.text, color: s.color, fs: r5(L.fs), lines: L.lines });
        continue;
      }
      const head = { op: 'begin', id: s.id, tool: s.tool, color: s.color, size: s.size };
      if (!s.pts.length) ops.push({ ...head, pts: [] });
      for (let i = 0; i < s.pts.length; i += PTS_CHUNK) {
        const chunk = s.pts.slice(i, i + PTS_CHUNK);
        ops.push(i === 0 ? { ...head, pts: chunk } : { op: 'pts', id: s.id, pts: chunk });
      }
      if (s.ended) ops.push({ op: 'end', id: s.id });
    }
    return ops;
  }

  const board = {
    get bg() { return bg; },
    get items() { return items; },
    get gen() { return gen; },
    // Set by the page: called after a pasted image finishes loading, so it can redraw.
    onImage: null,
    // The cache entry for image `k` ({ el, state }), or undefined if it was never asked for or was dropped.
    image: (k) => images.get(k),
    canUndo: () => undoStack.length > 0,
    canRedo: () => redoStack.length > 0,
    nextId: () => idSeq,
    apply,
    toOps,
    // Resolves once every image on the board has loaded or failed to; a missing file never blocks it.
    async imagesReady() {
      for (;;) {
        const waiting = items.filter((it) => it.kind === 'image').map((it) => loadImage(images, it.img)).filter((e) => e.state === 'loading');
        if (!waiting.length) return;
        await Promise.all(waiting.map((e) => e.done));
      }
    },
    // Collapse the history to exactly what a replay carries: reset, then toOps() applied back.
    // The page does this whenever it replays to the Mac, because the Mac only ever sees the replay;
    // doing it on both sides keeps undo and redo identical afterwards. Returns the ops.
    rebase() {
      const ops = toOps();
      apply({ op: 'reset', keepImages: true });   // no flicker: the pictures that stay are never reloaded
      for (const o of ops) apply(o);
      pruneImages();
      return ops;
    },
    // Items within r (a fraction of the board width) of x, y: the eraser. A stroke by its path, a shape by its
    // outline, a text label or sticky note by its box. Pasted images are never taken.
    hitTest(x, y, r) {
      const ay = y * H_OVER_W, ids = [];
      for (const s of items) {
        if (s.kind === 'image') continue;   // the eraser never takes a pasted image; undo and clear do
        if (s.kind === 'shape') { if (hitShape(s, x, ay, r)) ids.push(s.id); continue; }
        if (s.kind === 'text') {
          const b = textBox(s);
          if (distToBox(x, ay, s.x, s.y * H_OVER_W, b.w * H_OVER_W, b.h * H_OVER_W) <= r + 0.001) ids.push(s.id);
          continue;
        }
        if (s.kind === 'note') {
          if (distToBox(x, ay, s.x, s.y * H_OVER_W, s.w, s.h * H_OVER_W) <= r + 0.001) ids.push(s.id);
          continue;
        }
        const pts = s.pts;
        if (!pts.length) continue;
        const reach = r + s.size * (s.tool === 'marker' ? 2.2 : 1) / 2 + 0.001, lim2 = reach * reach;
        let px = pts[0][0], py = pts[0][1] * H_OVER_W;
        let hit = (px - x) * (px - x) + (py - ay) * (py - ay) <= lim2;
        for (let i = 1; i < pts.length && !hit; i++) {
          const qx = pts[i][0], qy = pts[i][1] * H_OVER_W;
          const dx = qx - px, dy = qy - py, len2 = dx * dx + dy * dy;
          const t = len2 ? Math.min(1, Math.max(0, ((x - px) * dx + (ay - py) * dy) / len2)) : 0;
          const cx = px + t * dx - x, cy = py + t * dy - ay;
          hit = cx * cx + cy * cy <= lim2;
          px = qx; py = qy;
        }
        if (hit) ids.push(s.id);
      }
      return ids;
    },
  };
  return board;
}

// ---------- Drawing ----------

// White ink on a light board draws black and black ink on a dark board draws white, so the two
// neutral colors stay readable when the background is cycled. Pure function of (color, bg).
function inkOn(color, bg) {
  if (isLight(bg)) return color === '#ffffff' ? '#000000' : color;
  return color === '#000000' ? '#ffffff' : color;
}

// Pen width at every point: a causal smoothing of the pressure curve, so the width never jumps and
// an earlier part of a growing stroke never changes when later points arrive.
function penWidths(pts, base) {
  const out = new Array(pts.length);
  let w = 0;
  for (let i = 0; i < pts.length; i++) {
    const p = pts[i][2] > 0 ? pts[i][2] : 0.5;
    const target = base * (0.22 + 0.78 * Math.pow(p, 0.6));
    w = i ? w + 0.35 * (target - w) : target;
    out[i] = Math.max(0.8, w);
  }
  return out;
}

// One stroke. Pen: a smoothed path (quadratic curves between segment midpoints) drawn piece by
// piece with round caps, the width following pressure. Marker: one wide flat path at about 35%
// opacity, darkening (multiply) on a light board and lightening (screen) on a dark one.
function drawStroke(ctx, w, h, s, bg) {
  const pts = s.pts, n = pts.length;
  if (!n) return;
  const color = inkOn(s.color, bg);
  const marker = s.tool === 'marker';
  const base = Math.max(1, s.size * w * (marker ? 2.2 : 1));
  const X = (i) => pts[i][0] * w, Y = (i) => pts[i][1] * h;
  const mx = (i) => (X(i) + X(i + 1)) / 2, my = (i) => (Y(i) + Y(i + 1)) / 2;   // midpoint of i, i+1
  ctx.save();
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  ctx.lineJoin = 'round';
  if (marker) {
    ctx.globalAlpha = 0.35;
    ctx.globalCompositeOperation = isLight(bg) ? 'multiply' : 'screen';
    ctx.lineCap = 'butt';
    ctx.lineWidth = base;
    ctx.beginPath();
    if (n === 1) {
      ctx.arc(X(0), Y(0), base / 2, 0, TAU);
      ctx.fill();
    } else {
      ctx.moveTo(X(0), Y(0));
      for (let i = 1; i < n - 1; i++) ctx.quadraticCurveTo(X(i), Y(i), mx(i), my(i));
      ctx.lineTo(X(n - 1), Y(n - 1));
      ctx.stroke();
    }
    ctx.restore();
    return;
  }
  ctx.lineCap = 'round';
  const sw = penWidths(pts, base);
  if (n === 1) {
    ctx.beginPath();
    ctx.arc(X(0), Y(0), sw[0] / 2, 0, TAU);
    ctx.fill();
  } else {
    const piece = (width, x0, y0, cx, cy, x1, y1) => {
      ctx.lineWidth = width;
      ctx.beginPath();
      ctx.moveTo(x0, y0);
      if (cx === null) ctx.lineTo(x1, y1); else ctx.quadraticCurveTo(cx, cy, x1, y1);
      ctx.stroke();
    };
    if (n === 2) {
      piece((sw[0] + sw[1]) / 2, X(0), Y(0), null, 0, X(1), Y(1));
    } else {
      piece(sw[0], X(0), Y(0), null, 0, mx(0), my(0));                                  // lead-in to the first midpoint
      for (let i = 1; i < n - 1; i++) piece(sw[i], mx(i - 1), my(i - 1), X(i), Y(i), mx(i), my(i));
      piece(sw[n - 1], mx(n - 2), my(n - 2), null, 0, X(n - 1), Y(n - 1));            // tail to the last point
    }
  }
  ctx.restore();
}

function drawBG(ctx, w, h, bg) {
  if (bg === 'white' || bg === 'grid') {
    ctx.fillStyle = '#ffffff';
  } else if (bg === 'dots') {
    ctx.fillStyle = '#10131a';
  } else {
    const g = ctx.createLinearGradient(0, 0, 0, h);
    g.addColorStop(0, '#12151d');
    g.addColorStop(1, '#0c0e15');
    ctx.fillStyle = g;
  }
  ctx.fillRect(0, 0, w, h);
  if (bg !== 'grid' && bg !== 'dots') return;
  const cell = w / 32;   // 32 by 18 cells on a 16:9 board
  ctx.save();
  if (bg === 'grid') {
    ctx.strokeStyle = 'rgba(70,80,105,0.22)';
    ctx.lineWidth = Math.max(1, w / 1600);
    ctx.beginPath();
    for (let x = cell; x < w - 0.5; x += cell) { ctx.moveTo(x, 0); ctx.lineTo(x, h); }
    for (let y = cell; y < h - 0.5; y += cell) { ctx.moveTo(0, y); ctx.lineTo(w, y); }
    ctx.stroke();
  } else {
    ctx.fillStyle = 'rgba(235,240,255,0.22)';
    const r = Math.max(1.1, w / 900);
    for (let y = cell / 2; y < h; y += cell) {
      for (let x = cell / 2; x < w; x += cell) {
        ctx.beginPath(); ctx.arc(x, y, r, 0, TAU); ctx.fill();
      }
    }
  }
  ctx.restore();
}

// A shape in the current ink: a line, an arrow (a line with a filled head that grows with the width),
// or a rectangle or ellipse outline spanning the two corners.
function drawShape(ctx, w, h, s, bg) {
  const lw = Math.max(1, s.size * w), color = inkOn(s.color, bg);
  const x0 = s.x0 * w, y0 = s.y0 * h, x1 = s.x1 * w, y1 = s.y1 * h;
  ctx.save();
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  ctx.lineWidth = lw;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.beginPath();
  if (s.shape === 'rect') {
    ctx.rect(Math.min(x0, x1), Math.min(y0, y1), Math.abs(x1 - x0), Math.abs(y1 - y0));
    ctx.stroke();
  } else if (s.shape === 'ellipse') {
    ctx.ellipse((x0 + x1) / 2, (y0 + y1) / 2, Math.abs(x1 - x0) / 2, Math.abs(y1 - y0) / 2, 0, 0, TAU);
    ctx.stroke();
  } else if (s.shape === 'arrow') {
    const len = Math.hypot(x1 - x0, y1 - y0);
    if (len < 1) { ctx.arc(x1, y1, lw / 2, 0, TAU); ctx.fill(); } else {
      const ux = (x1 - x0) / len, uy = (y1 - y0) / len;
      const head = Math.min(len, Math.max(lw * 4.5, w * 0.012));   // head length
      const bx = x1 - ux * head * 0.8, by = y1 - uy * head * 0.8;   // where the shaft meets the head
      ctx.moveTo(x0, y0); ctx.lineTo(bx, by);
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(x1, y1);
      ctx.lineTo(x1 - ux * head - uy * head * 0.5, y1 - uy * head + ux * head * 0.5);
      ctx.lineTo(x1 - ux * head + uy * head * 0.5, y1 - uy * head - ux * head * 0.5);
      ctx.closePath();
      ctx.fill();
    }
  } else {
    ctx.moveTo(x0, y0); ctx.lineTo(x1, y1);
    ctx.stroke();
  }
  ctx.restore();
}

// A text label: top-left at (x, y), one line per \n, in the current ink.
function drawText(ctx, w, h, it, bg) {
  const b = textBox(it);
  ctx.save();
  ctx.fillStyle = inkOn(it.color, bg);
  ctx.font = `${TEXT_WEIGHT} ${it.size * h}px ${FONT}`;
  ctx.textBaseline = 'alphabetic';
  ctx.textAlign = 'left';
  b.lines.forEach((l, i) => ctx.fillText(l, it.x * w, (it.y + (i * LINE_H + TEXT_BASE) * it.size) * h));
  ctx.restore();
}

// A sticky note: a soft tint of its color on a rounded card with a slight shadow, dark text inside.
function drawNote(ctx, w, h, it) {
  const x = it.x * w, y = it.y * h, cw = it.w * w, ch = it.h * h, r = Math.min(cw, ch) * 0.05;
  const n = parseInt(it.color.slice(1), 16);
  const tint = (v) => Math.round(v + (255 - v) * 0.7);
  ctx.save();
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + cw, y, x + cw, y + ch, r);
  ctx.arcTo(x + cw, y + ch, x, y + ch, r);
  ctx.arcTo(x, y + ch, x, y, r);
  ctx.arcTo(x, y, x + cw, y, r);
  ctx.closePath();
  ctx.shadowColor = 'rgba(0,0,0,0.4)';
  ctx.shadowBlur = h * 0.014;
  ctx.shadowOffsetY = h * 0.006;
  ctx.fillStyle = `rgb(${tint((n >> 16) & 255)},${tint((n >> 8) & 255)},${tint(n & 255)})`;
  ctx.fill();
  ctx.shadowColor = 'rgba(0,0,0,0)';
  ctx.clip();   // the text never leaves the card, however long it is
  const L = noteLayout(it);
  ctx.fillStyle = '#2a2a2c';
  ctx.font = `${NOTE_WEIGHT} ${L.fs * h}px ${FONT}`;
  ctx.textBaseline = 'alphabetic';
  ctx.textAlign = 'left';
  L.lines.forEach((l, i) => ctx.fillText(l, x + L.pad * h, y + (L.pad + (i * NOTE_LINE_H + NOTE_BASE) * L.fs) * h));
  ctx.restore();
}

// One item above the images, in creation order. (Images are drawn first, all together, by drawImages.)
function drawItem(ctx, w, h, it, bg) {
  if (it.kind === 'stroke') drawStroke(ctx, w, h, it, bg);
  else if (it.kind === 'shape') drawShape(ctx, w, h, it, bg);
  else if (it.kind === 'text') drawText(ctx, w, h, it, bg);
  else if (it.kind === 'note') drawNote(ctx, w, h, it);
}

// The whole board from scratch: background, then the images, then every live item in order.
function render(board, ctx, w, h) {
  drawBG(ctx, w, h, board.bg);
  drawImages(ctx, w, h, board);
  for (const s of board.items) drawItem(ctx, w, h, s, board.bg);
}

// The same picture, cheaper, for a canvas that redraws as strokes arrive. Background, images and
// finished strokes live in a cached layer that is rebuilt only when something already drawn changes
// (undo, redo, erase, clear, background, reset, resize, an image added or finished loading); the
// stroke being drawn goes on top each frame.
// The output is pixel-identical to render().
function createView() {
  let base = null, bctx = null, bw = 0, bh = 0, gen = -1, bg = '', baked = 0;
  return {
    draw(board, ctx, w, h) {
      if (!base) { base = document.createElement('canvas'); bctx = base.getContext('2d'); }
      if (bw !== w || bh !== h) { base.width = bw = w; base.height = bh = h; gen = -1; }
      if (gen !== board.gen || bg !== board.bg) {
        drawBG(bctx, w, h, board.bg);
        drawImages(bctx, w, h, board);
        gen = board.gen; bg = board.bg; baked = 0;
      }
      const list = board.items;
      while (baked < list.length && list[baked].ended) drawItem(bctx, w, h, list[baked++], board.bg);
      ctx.drawImage(base, 0, 0);
      for (let i = baked; i < list.length; i++) drawItem(ctx, w, h, list[i], board.bg);
    },
  };
}

globalThis.PencilBoardCore = { BGS, SHAPES, createBoard, createView, render, drawItem, drawStroke, drawBG, inkOn, fitNote };
})();
