// PencilPad effects: a swipe trail on a plain dark 2D canvas behind the page.
// Reads pen events from app.js's queue once per frame. Never touches input or the socket.

import { DOWN, MOVE, UP, LEAVE } from './app.js';

const BG = '#05060b';
const GLINT_CAP = 48;
const POINT_CAP = 400;       // points kept per stroke, so a long scribble cannot grow the work
const ALPHA_STEPS = 8, HUE_STEPS = 12;

// Looks: life is seconds until a point is gone; width is the half width of the thickest part, in CSS px.
const LOOKS = {
  line: { life: 1.0, smooth: 1 },
  blade: { life: 0.4, smooth: 0.6, width: 9 },
  rainbow: { life: 0.6, smooth: 0.6, width: 8 },
};

export function start({ canvas, queue }) {
  const ctx = canvas.getContext('2d', { alpha: false });
  let W = 0, H = 0;

  function resize() {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    W = innerWidth; H = innerHeight;
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    dirty = true;
  }

  // ---------- State written from the queue ----------

  const t0 = performance.now();
  let look = LOOKS.line;
  let read = queue.head;
  let strokes = [];            // each: { x, y, p, t, n } typed arrays grown on demand, oldest first, n points in use
  let glints = [];             // { x, y, vx, vy, t }
  let cur = null, mx = 0, my = 0;
  let dirty = true;            // the canvas shows something other than a clean background

  function newStroke(x, y, p, t) {
    const s = { x: new Float32Array(32), y: new Float32Array(32), p: new Float32Array(32), t: new Float32Array(32), n: 0 };
    addPoint(s, x, y, p, t);
    return s;
  }

  function addPoint(s, x, y, p, t) {
    if (s.n === POINT_CAP) dropOldest(s, POINT_CAP >> 3);
    if (s.n === s.x.length) {
      for (const k of ['x', 'y', 'p', 't']) { const a = new Float32Array(s.n * 2); a.set(s[k]); s[k] = a; }
    }
    const n = s.n++;
    s.x[n] = x; s.y[n] = y; s.p[n] = p; s.t[n] = t;
  }

  function dropOldest(s, k) {
    s.x.copyWithin(0, k, s.n); s.y.copyWithin(0, k, s.n); s.p.copyWithin(0, k, s.n); s.t.copyWithin(0, k, s.n);
    s.n -= k;
  }

  function drain() {
    const b = queue.buf, S = queue.stride, cap = queue.cap;
    let i = Math.max(read, queue.head - cap);
    for (; i < queue.head; i++) {
      const o = (i % cap) * S;
      const type = b[o], sx = b[o + 1], sy = b[o + 2], p = b[o + 3];
      const t = (b[o + 7] - t0) / 1000;
      if (type === DOWN) {
        mx = sx; my = sy;
        cur = newStroke(sx, sy, p, t);
        strokes.push(cur);
      } else if (type === MOVE) {
        if (!cur) continue;
        const px = mx, py = my;
        mx += (sx - mx) * look.smooth; my += (sy - my) * look.smooth;
        const d = Math.hypot(mx - px, my - py);
        if (d < 0.8) continue;
        addPoint(cur, mx, my, p, t);
        if (look === LOOKS.blade && d > 16 && Math.random() < 0.5) {
          if (glints.length >= GLINT_CAP) glints.shift();
          const a = Math.random() * 6.2832, v = 30 + Math.random() * 60;
          glints.push({ x: mx + (Math.random() - 0.5) * 10, y: my + (Math.random() - 0.5) * 10, vx: Math.cos(a) * v, vy: Math.sin(a) * v, t });
        }
      } else if (type === UP || type === LEAVE) {
        cur = null;
      }
    }
    read = queue.head;
  }

  // ---------- Drawing ----------

  function prune(t) {
    for (const s of strokes) {
      let n = 0;
      while (n < s.n && t - s.t[n] > look.life) n++;
      if (n) dropOldest(s, n);
    }
    strokes = strokes.filter((s) => s.n > 0 || s === cur);
    while (glints.length && t - glints[0].t > 0.3) glints.shift();
  }

  // Colour strings for every bucket, built once: index = alpha step (1..ALPHA_STEPS), plus a hue step for rainbow.
  const alphaOf = (max, a) => (max * a / ALPHA_STEPS).toFixed(3);
  const flat = (rgb, max) => Array.from({ length: ALPHA_STEPS + 1 }, (_, a) => `rgba(${rgb},${alphaOf(max, a)})`);
  const hued = (sat, light, max) => Array.from({ length: HUE_STEPS * (ALPHA_STEPS + 1) }, (_, k) =>
    `hsla(${Math.round(300 * (Math.floor(k / (ALPHA_STEPS + 1)) + 0.5) / HUE_STEPS)},100%,${light}%,${alphaOf(max, k % (ALPHA_STEPS + 1))})`);
  const LINE_C = flat('255,59,48', 1);
  const GLINT_C = flat('255,255,255', 1);
  const BLADE_EDGE = flat('140,152,170', 0.45), BLADE_CORE = flat('246,249,255', 1);
  const RAIN_BODY = hued(100, 58, 1), RAIN_CORE = hued(100, 88, 0.5);

  // Scratch space shared by every stroke: sized for the point cap, so nothing is allocated per frame.
  const nx = new Float32Array(POINT_CAP), ny = new Float32Array(POINT_CAP), w = new Float32Array(POINT_CAP), a = new Float32Array(POINT_CAP);
  const key = new Uint16Array(POINT_CAP), order = new Uint16Array(POINT_CAP);
  const start = new Uint16Array(HUE_STEPS * (ALPHA_STEPS + 1) + 1);

  // Alpha step 1..ALPHA_STEPS for an alpha 0..1 (0 when invisible).
  const step = (al) => Math.ceil(al * ALPHA_STEPS - 1e-6);

  // Counting sort of the segments 1..n-1 by key (0 = skip) into `order`; start[k]..start[k+1] is bucket k.
  function sortKeys(n, nKeys) {
    start.fill(0, 0, nKeys + 1);
    for (let i = 1; i < n; i++) start[key[i] + 1]++;
    for (let k = 0; k < nKeys; k++) start[k + 1] += start[k];
    for (let i = 1; i < n; i++) order[start[key[i]]++] = i;
    // start[k] is now the end of bucket k; the beginning is the end of bucket k - 1.
  }

  function drawLine(t) {
    ctx.lineWidth = 3; ctx.lineCap = 'round';
    for (const s of strokes) {
      const n = s.n;
      for (let i = 1; i < n; i++) key[i] = step(1 - (t - s.t[i]) / look.life);
      sortKeys(n, ALPHA_STEPS + 1);
      for (let k = 1; k <= ALPHA_STEPS; k++) {
        const from = start[k - 1], to = start[k];
        if (from === to) continue;
        ctx.strokeStyle = LINE_C[k];
        ctx.beginPath();
        for (let j = from; j < to; j++) { const i = order[j]; ctx.moveTo(s.x[i - 1], s.y[i - 1]); ctx.lineTo(s.x[i], s.y[i]); }
        ctx.stroke();
      }
    }
  }

  // A tapered strip along a stroke: thick in the middle of what is alive, a point at both ends.
  // Normals, widths and fades are worked out once per stroke; each pass draws it at a width scale k, one fill per colour bucket.
  function drawTapered(t) {
    const rainbow = look === LOOKS.rainbow;
    const hueSteps = rainbow ? HUE_STEPS : 1, nKeys = hueSteps * (ALPHA_STEPS + 1);
    for (const s of strokes) {
      const n = s.n;
      if (n < 2) continue;
      for (let i = 0; i < n; i++) {
        const j0 = Math.max(0, i - 1), j1 = Math.min(n - 1, i + 1);
        const dx = s.x[j1] - s.x[j0], dy = s.y[j1] - s.y[j0], d = Math.hypot(dx, dy) || 1;
        nx[i] = -dy / d; ny[i] = dx / d;
        w[i] = look.width * Math.pow(Math.sin(Math.PI * i / (n - 1)), 0.75) * (0.7 + 0.6 * s.p[i]);
        a[i] = Math.pow(Math.max(0, 1 - (t - s.t[i]) / look.life), 1.3);
      }
      const pass = (k, colors) => {
        for (let i = 1; i < n; i++) {
          const st = step((a[i] + a[i - 1]) / 2);
          key[i] = st > 0 ? (rainbow ? Math.min(HUE_STEPS - 1, Math.floor(HUE_STEPS * i / (n - 1))) * (ALPHA_STEPS + 1) : 0) + Math.min(st, ALPHA_STEPS) : 0;
        }
        sortKeys(n, nKeys);
        for (let q = 1; q < nKeys; q++) {
          const from = start[q - 1], to = start[q];
          if (from === to) continue;
          ctx.fillStyle = colors[q];
          ctx.beginPath();
          for (let j = from; j < to; j++) {
            const i = order[j];
            ctx.moveTo(s.x[i - 1] + nx[i - 1] * w[i - 1] * k, s.y[i - 1] + ny[i - 1] * w[i - 1] * k);
            ctx.lineTo(s.x[i] + nx[i] * w[i] * k, s.y[i] + ny[i] * w[i] * k);
            ctx.lineTo(s.x[i] - nx[i] * w[i] * k, s.y[i] - ny[i] * w[i] * k);
            ctx.lineTo(s.x[i - 1] - nx[i - 1] * w[i - 1] * k, s.y[i - 1] - ny[i - 1] * w[i - 1] * k);
            ctx.closePath();
          }
          ctx.fill();
        }
      };
      if (!rainbow) {
        pass(1, BLADE_EDGE);   // soft cool-gray edge
        pass(0.5, BLADE_CORE);    // bright silver-white core
      } else {
        pass(1, RAIN_BODY);
        pass(0.3, RAIN_CORE);   // light core
      }
    }
    if (glints.length) {
      const bucket = Array.from({ length: ALPHA_STEPS + 1 }, () => []);
      for (const g of glints) {
        const k = (t - g.t) / 0.3;
        if (k < 1) bucket[step(1 - k)].push(g, k);
      }
      for (let st = 1; st <= ALPHA_STEPS; st++) {
        const list = bucket[st];
        if (!list.length) continue;
        ctx.fillStyle = GLINT_C[st];
        ctx.beginPath();
        for (let j = 0; j < list.length; j += 2) {
          const g = list[j], k = list[j + 1], age = k * 0.3, x = g.x + g.vx * age, y = g.y + g.vy * age;
          ctx.moveTo(x, y); ctx.arc(x, y, 2.2 * (1 - k) + 0.4, 0, 6.2832);
        }
        ctx.fill();
      }
    }
  }

  // ---------- Frame loop ----------

  let raf = 0, running = false, quiet = false, styled = false;

  // Draws while anything is alive, then lets go of rAF; the next pen event (queue.wake) starts it again.
  function frame(now) {
    raf = 0;
    const t = (now - t0) / 1000;
    drain();
    prune(t);
    if (!strokes.length && !glints.length) {
      if (!dirty) return;   // nothing alive and the background is already clean: stop until the next pen event
      dirty = false;
    } else dirty = true;
    ctx.fillStyle = BG;
    ctx.fillRect(0, 0, W, H);
    if (look === LOOKS.line) drawLine(t); else drawTapered(t);
    if (strokes.length || glints.length) raf = requestAnimationFrame(frame);
  }

  function wake() { if (running && !raf) raf = requestAnimationFrame(frame); }
  queue.wake = wake;

  function run(on) {
    on = on && !quiet;
    if (on === running) return;
    running = on;
    if (on) { read = queue.head; dirty = true; wake(); }
    else { cancelAnimationFrame(raf); raf = 0; }
  }

  function setStyle(name) {
    if (!LOOKS[name]) { styled = false; cur = null; run(false); return; }
    styled = true;
    look = LOOKS[name];
    strokes = []; glints = []; cur = null; dirty = true;
    run(true); wake();
  }

  // Stopped, not hidden: no frames at all while the Board, Annotate or a projected picture has the page.
  function setQuiet(q) {
    quiet = q;
    if (q) { cur = null; run(false); } else run(styled);
  }

  function clear() { strokes = []; glints = []; cur = null; dirty = true; wake(); }

  addEventListener('resize', resize);
  resize();
  return { setStyle, setQuiet, clear };
}
