// PencilPad effects: a swipe trail on a plain dark 2D canvas behind the page.
// Reads pen events from app.js's queue once per frame. Never touches input or the socket.

import { DOWN, MOVE, UP, LEAVE } from './app.js';

const BG = '#05060b';
const GLINT_CAP = 48;

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
  let strokes = [];            // each: { x, y, p, t } point arrays, oldest first
  let glints = [];             // { x, y, vx, vy, t }
  let cur = null, mx = 0, my = 0;
  let dirty = true;            // the canvas shows something other than a clean background

  function drain() {
    const b = queue.buf, S = queue.stride, cap = queue.cap;
    let i = Math.max(read, queue.head - cap);
    for (; i < queue.head; i++) {
      const o = (i % cap) * S;
      const type = b[o], sx = b[o + 1], sy = b[o + 2], p = b[o + 3];
      const t = (b[o + 7] - t0) / 1000;
      if (type === DOWN) {
        mx = sx; my = sy;
        cur = { x: [sx], y: [sy], p: [p], t: [t] };
        strokes.push(cur);
      } else if (type === MOVE) {
        if (!cur) continue;
        const px = mx, py = my;
        mx += (sx - mx) * look.smooth; my += (sy - my) * look.smooth;
        const d = Math.hypot(mx - px, my - py);
        if (d < 0.8) continue;
        cur.x.push(mx); cur.y.push(my); cur.p.push(p); cur.t.push(t);
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
      while (n < s.t.length && t - s.t[n] > look.life) n++;
      if (n) { s.x.splice(0, n); s.y.splice(0, n); s.p.splice(0, n); s.t.splice(0, n); }
    }
    strokes = strokes.filter((s) => s.t.length > 0 || s === cur);
    while (glints.length && t - glints[0].t > 0.3) glints.shift();
  }

  function drawLine(t) {
    ctx.lineWidth = 3; ctx.lineCap = 'round';
    for (const s of strokes) {
      for (let i = 1; i < s.t.length; i++) {
        const a = 1 - (t - s.t[i]) / look.life;
        if (a <= 0) continue;
        ctx.strokeStyle = `rgba(255,59,48,${a.toFixed(3)})`;
        ctx.beginPath(); ctx.moveTo(s.x[i - 1], s.y[i - 1]); ctx.lineTo(s.x[i], s.y[i]); ctx.stroke();
      }
    }
  }

  // A tapered strip along a stroke: thick in the middle of what is alive, a point at both ends.
  // Normals, widths and fades are worked out once per stroke; each pass draws it at a width scale k.
  function drawTapered(t) {
    for (const s of strokes) {
      const n = s.t.length;
      if (n < 2) continue;
      const nx = new Float32Array(n), ny = new Float32Array(n), w = new Float32Array(n), a = new Float32Array(n);
      for (let i = 0; i < n; i++) {
        const j0 = Math.max(0, i - 1), j1 = Math.min(n - 1, i + 1);
        const dx = s.x[j1] - s.x[j0], dy = s.y[j1] - s.y[j0], d = Math.hypot(dx, dy) || 1;
        nx[i] = -dy / d; ny[i] = dx / d;
        w[i] = look.width * Math.pow(Math.sin(Math.PI * i / (n - 1)), 0.75) * (0.7 + 0.6 * s.p[i]);
        a[i] = Math.pow(Math.max(0, 1 - (t - s.t[i]) / look.life), 1.3);
      }
      const pass = (k, alpha, color) => {
        for (let i = 1; i < n; i++) {
          const al = alpha * (a[i] + a[i - 1]) / 2;
          if (al <= 0.003) continue;
          ctx.fillStyle = color(i, al);
          ctx.beginPath();
          ctx.moveTo(s.x[i - 1] + nx[i - 1] * w[i - 1] * k, s.y[i - 1] + ny[i - 1] * w[i - 1] * k);
          ctx.lineTo(s.x[i] + nx[i] * w[i] * k, s.y[i] + ny[i] * w[i] * k);
          ctx.lineTo(s.x[i] - nx[i] * w[i] * k, s.y[i] - ny[i] * w[i] * k);
          ctx.lineTo(s.x[i - 1] - nx[i - 1] * w[i - 1] * k, s.y[i - 1] - ny[i - 1] * w[i - 1] * k);
          ctx.fill();
        }
      };
      if (look === LOOKS.blade) {
        ctx.globalCompositeOperation = 'lighter';
        pass(2.4, 0.07, (i, al) => `rgba(170,190,220,${al.toFixed(3)})`);   // the very light bloom
        ctx.globalCompositeOperation = 'source-over';
        pass(1, 0.45, (i, al) => `rgba(140,152,170,${al.toFixed(3)})`);     // soft cool-gray edge
        pass(0.5, 1, (i, al) => `rgba(246,249,255,${al.toFixed(3)})`);      // bright silver-white core
      } else {
        const hue = (i) => Math.round(300 * i / (n - 1));
        ctx.globalCompositeOperation = 'lighter';
        pass(2, 0.18, (i, al) => `hsla(${hue(i)},100%,60%,${al.toFixed(3)})`);   // light bloom
        ctx.globalCompositeOperation = 'source-over';
        pass(1, 1, (i, al) => `hsla(${hue(i)},100%,58%,${al.toFixed(3)})`);
        pass(0.3, 0.5, (i, al) => `hsla(${hue(i)},100%,88%,${al.toFixed(3)})`);
      }
    }
    for (const g of glints) {
      const age = t - g.t, k = age / 0.3;
      if (k >= 1) continue;
      ctx.fillStyle = `rgba(255,255,255,${(1 - k).toFixed(3)})`;
      ctx.beginPath(); ctx.arc(g.x + g.vx * age, g.y + g.vy * age, 2.2 * (1 - k) + 0.4, 0, 6.2832); ctx.fill();
    }
  }

  // ---------- Frame loop ----------

  let raf = 0, running = false, quiet = false, styled = false;

  function frame(now) {
    raf = requestAnimationFrame(frame);
    const t = (now - t0) / 1000;
    drain();
    prune(t);
    if (!strokes.length && !glints.length) {
      if (!dirty) return;   // nothing alive and the background is already clean: no drawing at all
      dirty = false;
    } else dirty = true;
    ctx.fillStyle = BG;
    ctx.fillRect(0, 0, W, H);
    if (look === LOOKS.line) drawLine(t); else drawTapered(t);
  }

  function run(on) {
    on = on && !quiet;
    if (on === running) return;
    running = on;
    if (on) { read = queue.head; dirty = true; raf = requestAnimationFrame(frame); }
    else cancelAnimationFrame(raf);
  }

  function setStyle(name) {
    if (!LOOKS[name]) { styled = false; cur = null; run(false); return; }
    styled = true;
    look = LOOKS[name];
    strokes = []; glints = []; cur = null; dirty = true;
    run(true);
  }

  // Stopped, not hidden: no frames at all while the Board, Annotate or a projected picture has the page.
  function setQuiet(q) {
    quiet = q;
    if (q) { cur = null; run(false); } else run(styled);
  }

  function clear() { strokes = []; glints = []; cur = null; dirty = true; }

  addEventListener('resize', resize);
  resize();
  return { setStyle, setQuiet, clear };
}
