// PencilPad effects: the three.js scene behind the page.
// Reads pen events from app.js's queue once per frame. Never touches input or the socket.
// All buffers are allocated once; per frame it only writes into rings and uniforms.

import {
  WebGLRenderer, WebGLRenderTarget, Scene, OrthographicCamera, Mesh, Points, PlaneGeometry,
  BufferGeometry, BufferAttribute, ShaderMaterial, AdditiveBlending, DoubleSide, DynamicDrawUsage,
  HalfFloatType, NoToneMapping, Color, Vector2, Vector3, Vector4,
} from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { HOVER, DOWN, MOVE, UP, LEAVE } from './app.js';

const SEG_CAP = 6144;     // ribbon segments kept in the ring (4 vertices each)
const SPARK_CAP = 2400;   // spark particles in the ring
const DUST = 240;         // drifting background motes
const RIPPLES = 8;        // grid ripples alive at once

// Looks. Colors are sRGB hex; three converts them to linear.
const LOOKS = {
  neon: {
    id: 0, bgA: 0x020309, bgB: 0x0c0a26, neb: 0x2a0f5c, grid: 0x35e6ff, dust: 0x7fdcff,
    a: 0x2ef2ff, b: 0xff32d2, c: 0xf2ffff, ret: 0x5ff6ff, ret2: 0xffffff,
    life: 2.6, width: 1.7, gridAmt: 1.0,
    bloom: [1.0, 0.55, 0.16],
    spark: { drag: 2.4, gx: 0, gy: 0, sway: 0, v0: 160, v1: 620, l0: 0.45, l1: 1.1, s0: 4, s1: 9, rate: 0.16, burst: 36, lift: 0 },
  },
  aurora: {
    id: 1, bgA: 0x010507, bgB: 0x07142a, neb: 0x0b5a4c, grid: 0x5dffc0, dust: 0xa8ffe0,
    a: 0x34ffa0, b: 0x8f5cff, c: 0xe2fff4, ret: 0x7dffc8, ret2: 0xe9ddff,
    life: 3.6, width: 1.9, gridAmt: 0.75,
    bloom: [0.8, 0.85, 0.12],
    spark: { drag: 1.1, gx: 0, gy: -36, sway: 26, v0: 30, v1: 160, l0: 1.4, l1: 3.0, s0: 5, s1: 12, rate: 0.07, burst: 22, lift: 30 },
  },
  ember: {
    id: 2, bgA: 0x050202, bgB: 0x1a0905, neb: 0x5a1a06, grid: 0xffa640, dust: 0xffb070,
    a: 0xffd47a, b: 0xff4a14, c: 0xfff3da, ret: 0xffb547, ret2: 0xfff1cf,
    life: 3.0, width: 1.25, gridAmt: 0.7,
    bloom: [1.15, 0.5, 0.12],
    spark: { drag: 1.2, gx: 0, gy: 480, sway: 0, v0: 180, v1: 700, l0: 0.7, l1: 1.7, s0: 3, s1: 7, rate: 0.24, burst: 48, lift: 300 },
  },
};

const BG_VS = /* glsl */`
void main() { gl_Position = vec4(position.xy, 0.0, 1.0); }`;

const BG_FS = /* glsl */`
uniform float uTime, uDpr, uGridAmt;
uniform vec2 uRes;
uniform vec4 uArea;
uniform vec4 uRip[${RIPPLES}];
uniform vec3 uHover, uBgA, uBgB, uNeb, uGrid;

float hash(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p), u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 3; i++) { v += a * noise(p); p = p * 2.03 + 17.1; a *= 0.5; } return v; }

void main() {
  vec2 res = uRes / uDpr;
  vec2 px = vec2(gl_FragCoord.x, uRes.y - gl_FragCoord.y) / uDpr;
  vec2 uv = px / res;
  float r = length((uv - vec2(0.5, 0.42)) * vec2(res.x / res.y, 1.0));
  vec3 col = mix(uBgB, uBgA, smoothstep(0.0, 0.95, r));

  float n = fbm(px * 0.0019 + vec2(uTime * 0.013, -uTime * 0.009));
  float n2 = fbm(px * 0.0037 - vec2(uTime * 0.018, uTime * 0.011) + n * 1.8);
  col += uNeb * smoothstep(0.38, 1.0, n2) * 0.8;

  vec2 q = px; float wave = 0.0;
  for (int i = 0; i < ${RIPPLES}; i++) {
    vec4 rp = uRip[i];
    float age = uTime - rp.z;
    if (age < 0.0 || age > 2.6) continue;
    vec2 d = px - rp.xy; float dist = length(d) + 1e-3;
    float band = exp(-pow((dist - age * 420.0) / 46.0, 2.0)) * exp(-age * 1.7) * rp.w;
    q -= d / dist * band * 9.0;
    wave += band;
  }
  const float cell = 46.0;
  vec2 g = abs(fract(q / cell + 0.5) - 0.5) * cell;
  float line = 1.0 - smoothstep(0.0, 1.1, min(g.x, g.y));
  float node = 1.0 - smoothstep(0.6, 2.2, length(g));
  vec2 hd = px - uHover.xy;
  float hv = uHover.z * exp(-dot(hd, hd) / 28800.0);
  vec2 e = min(px - uArea.xy, uArea.xy + uArea.zw - px);
  float inside = smoothstep(0.0, 26.0, min(e.x, e.y));
  float wv = 1.0 - exp(-wave * 1.4);
  float gi = (line * (0.045 + 0.3 * wv + 0.2 * hv) + node * (0.1 + 0.5 * wv + 0.45 * hv)) * inside * uGridAmt;
  col += uGrid * (gi + (wv * 0.02 + hv * 0.02) * inside);
  col *= 1.0 - 0.38 * smoothstep(0.55, 1.25, r);
  gl_FragColor = vec4(col, 1.0);
}`;

const DUST_VS = /* glsl */`
attribute vec3 aMisc;           // speed, size, twinkle seed
uniform float uTime, uDpr;
uniform vec2 uView;
uniform vec3 uHover;
varying float vA;
void main() {
  vec2 p = position.xy * (uView + 40.0) + vec2(sin(uTime * 0.07 * aMisc.x + position.z * 6.2832) * 30.0, -uTime * aMisc.x * 9.0);
  p = mod(p, uView + 40.0) - 20.0;
  vec2 d = p - uHover.xy; float dl = length(d) + 1.0;
  p += d / dl * 28.0 * exp(-dl / 90.0) * uHover.z;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 0.0, 1.0);
  gl_PointSize = aMisc.y * uDpr;
  vA = 0.22 + 0.3 * sin(uTime * (0.6 + aMisc.z * 1.4) + aMisc.z * 30.0);
}`;

const DUST_FS = /* glsl */`
uniform vec3 uDust;
varying float vA;
void main() {
  vec2 c = gl_PointCoord - 0.5;
  float a = exp(-dot(c, c) * 14.0) * max(vA, 0.0);
  gl_FragColor = vec4(uDust * a, 1.0);
}`;

const RIBBON_VS = /* glsl */`
attribute vec2 aOff;            // offset from the stroke center to this edge
attribute vec4 aInfo;           // birth, side (-1/+1), pressure, segment birth (kill time)
uniform float uTime, uLife, uClearAt;
varying float vSide, vK, vP, vB, vFade, vFresh;
void main() {
  float fade = aInfo.w < uClearAt ? clamp(1.0 - (uTime - uClearAt) / 0.35, 0.0, 1.0) : 1.0;
  if (uTime - aInfo.w > uLife || fade <= 0.0) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }
  float age = max(uTime - aInfo.x, 0.0);
  float k = clamp(age / uLife, 0.0, 1.0);
  float swell = 1.0 + 0.7 * exp(-age * 10.0);
  vec2 p = position.xy + aOff * mix(1.0, 0.3, k * k) * swell;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 0.0, 1.0);
  vSide = aInfo.y; vK = k; vP = aInfo.z; vB = aInfo.x; vFade = fade; vFresh = exp(-age * 4.0);
}`;

const RIBBON_FS = /* glsl */`
uniform int uStyle;
uniform float uTime;
uniform vec3 uA, uB, uC;
varying float vSide, vK, vP, vB, vFade, vFresh;
void main() {
  float s = abs(vSide);
  float edge = 1.0 - smoothstep(0.72, 1.0, s);
  float core = exp(-s * s * 26.0);
  float mid = exp(-s * s * 7.0);
  float halo = exp(-s * s * 2.2) * edge;
  float life = pow(1.0 - vK, 1.5) * vFade;
  vec3 col;
  if (uStyle == 0) {
    float fringe = halo * smoothstep(0.3, 0.7, s);   // magenta only outside the cyan body
    col = uC * core * (0.45 + 1.0 * vFresh) + uA * mid * (0.55 + 0.45 * vP) + uB * fringe * 0.9;
  } else if (uStyle == 1) {
    float h = 0.5 + 0.5 * sin(vB * 2.2 + vSide * 0.8 + uTime * 0.35);
    float bands = 0.75 + 0.35 * sin(vB * 38.0 - uTime * 2.6 + vSide * 2.0);
    col = mix(uA, uB, h) * (mid * 0.8 + halo * 0.5) * bands * 1.1 + uC * core * (0.3 + 1.0 * vFresh);
  } else {
    float heat = clamp(1.0 - vK * 1.25 + 0.3 * vP, 0.0, 1.0);
    col = uC * core * heat * (0.5 + 1.6 * vFresh) + mix(uB, uA, heat) * mid * (0.5 + 0.8 * heat) + uB * halo * 0.35 * (0.4 + heat);
    col *= 0.86 + 0.14 * sin(uTime * 23.0 + vB * 90.0);
  }
  gl_FragColor = vec4(col * life, 1.0);
}`;

const SPARK_VS = /* glsl */`
attribute vec3 aVel;            // vx, vy, life
attribute vec2 aMisc;           // size, seed
uniform float uTime, uDpr, uDrag, uSway, uClearAt;
uniform vec2 uGrav;
varying float vK, vSeed;
void main() {
  float t = uTime - position.z;
  if (t < 0.0 || t > aVel.z || position.z < uClearAt) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); gl_PointSize = 0.0; return; }
  float k = t / aVel.z;
  vec2 p = position.xy + aVel.xy * (1.0 - exp(-uDrag * t)) / uDrag + 0.5 * uGrav * t * t;
  p.x += sin(t * 4.0 + aMisc.y * 40.0) * uSway * t;
  gl_Position = projectionMatrix * modelViewMatrix * vec4(p, 0.0, 1.0);
  gl_PointSize = aMisc.x * uDpr * (1.0 - 0.65 * k);
  vK = k; vSeed = aMisc.y;
}`;

const SPARK_FS = /* glsl */`
uniform int uStyle;
uniform float uTime;
uniform vec3 uA, uB, uC;
varying float vK, vSeed;
void main() {
  vec2 c = gl_PointCoord - 0.5;
  float r2 = dot(c, c) * 4.0;
  float fall = 1.0 - vK;
  float a = exp(-r2 * 3.0) * fall * 1.3;
  float core = exp(-r2 * 14.0) * fall;
  vec3 col;
  if (uStyle == 0) col = mix(uA, uB, step(0.62, vSeed)) * a * 1.4 + uC * core * 1.2;
  else if (uStyle == 1) col = mix(uA, uB, vSeed) * a * 0.9 + uC * core * 0.35;
  else col = (mix(uB * 0.6, uA, fall) * a * 1.6 + uC * core * fall * 1.5) * (0.7 + 0.3 * sin(uTime * 40.0 + vSeed * 200.0));
  gl_FragColor = vec4(col, 1.0);
}`;

const RET_VS = /* glsl */`
varying vec2 vUv;
void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`;

const RET_FS = /* glsl */`
uniform float uTime, uA, uDown, uP, uArmed;
uniform vec3 uC1, uC2, uArm;
varying vec2 vUv;
void main() {
  vec2 c = (vUv - 0.5) * 2.0;
  float r = length(c);
  float ang = atan(c.y, c.x);
  float R = mix(0.42, 0.17, uDown);
  float ring = exp(-pow((r - R) / 0.016, 2.0));
  float halo = exp(-pow((r - R) / 0.13, 2.0)) * 0.14;
  float rot = uTime * mix(0.7, 2.6, uArmed);
  float tick = pow(abs(cos((ang - rot) * 2.0)), 160.0) * smoothstep(R + 0.06, R + 0.08, r) * (1.0 - smoothstep(R + 0.13, R + 0.16, r));
  float dash = mix(1.0, step(0.0, sin((ang + uTime * 3.0) * 9.0)), uArmed);
  float tip = exp(-r * r / 0.003) * (0.5 + 1.5 * uDown);
  float arcT = fract((ang + 1.5708) / 6.28318 + 1.0);
  float arc = uDown * step(arcT, uP) * exp(-pow((r - R - 0.11) / 0.018, 2.0));
  vec3 base = mix(uC1, uArm, uArmed);
  vec3 col = base * (ring * dash * 1.15 + halo + tick * 0.7 + arc * 1.5) + uC2 * tip * 1.1;
  gl_FragColor = vec4(col * uA, 1.0);
}`;

export function start({ canvas, queue, ui }) {
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const renderer = new WebGLRenderer({
    canvas, antialias: false, alpha: false, depth: false, stencil: false, powerPreference: 'high-performance',
  });
  renderer.setPixelRatio(dpr);
  renderer.toneMapping = NoToneMapping;
  let W = innerWidth, H = innerHeight;
  renderer.setSize(W, H, false);

  const scene = new Scene();
  const camera = new OrthographicCamera(0, W, 0, H, -10, 10);   // CSS px, y down

  // Shared uniforms (one object, many materials).
  const uTime = { value: 0 }, uDpr = { value: dpr }, uStyle = { value: 0 }, uClearAt = { value: -1 };
  const uA = { value: new Color() }, uB = { value: new Color() }, uC = { value: new Color() };
  const uHover = { value: new Vector3(-9999, -9999, 0) };   // x, y, strength
  // The y-down camera flips winding, so draw both sides.
  const additive = { transparent: true, depthTest: false, depthWrite: false, blending: AdditiveBlending, side: DoubleSide };

  // Background.
  const ripples = Array.from({ length: RIPPLES }, () => new Vector4(0, 0, -99, 0));
  const bgU = {
    uTime, uDpr, uRes: { value: new Vector2() }, uArea: { value: new Vector4() }, uRip: { value: ripples },
    uHover, uBgA: { value: new Color() }, uBgB: { value: new Color() }, uNeb: { value: new Color() },
    uGrid: { value: new Color() }, uGridAmt: { value: 1 },
  };
  const bg = new Mesh(new PlaneGeometry(2, 2), new ShaderMaterial({
    uniforms: bgU, vertexShader: BG_VS, fragmentShader: BG_FS, depthTest: false, depthWrite: false,
  }));
  bg.frustumCulled = false; bg.renderOrder = 0;
  scene.add(bg);

  // Dust.
  const dg = new BufferGeometry();
  const dPos = new Float32Array(DUST * 3), dMisc = new Float32Array(DUST * 3);
  for (let i = 0; i < DUST; i++) {
    dPos[i * 3] = Math.random(); dPos[i * 3 + 1] = Math.random(); dPos[i * 3 + 2] = Math.random();
    dMisc[i * 3] = 0.4 + Math.random() * 1.6; dMisc[i * 3 + 1] = 1.2 + Math.random() * 2.4; dMisc[i * 3 + 2] = Math.random();
  }
  dg.setAttribute('position', new BufferAttribute(dPos, 3));
  dg.setAttribute('aMisc', new BufferAttribute(dMisc, 3));
  const dustU = { uTime, uDpr, uView: { value: new Vector2(W, H) }, uHover, uDust: { value: new Color() } };
  const dust = new Points(dg, new ShaderMaterial({ uniforms: dustU, vertexShader: DUST_VS, fragmentShader: DUST_FS, ...additive }));
  dust.frustumCulled = false; dust.renderOrder = 1;
  scene.add(dust);

  // Ribbons: a ring of independent quads; joints are mitered by rewriting the previous quad's end.
  const RV = SEG_CAP * 4;
  const rPos = new Float32Array(RV * 3), rOff = new Float32Array(RV * 2), rInfo = new Float32Array(RV * 4);
  for (let i = 0; i < RV; i++) { rInfo[i * 4] = -1e6; rInfo[i * 4 + 3] = -1e6; }
  const rIdx = new Uint16Array(SEG_CAP * 6);
  for (let s = 0; s < SEG_CAP; s++) {
    const v = s * 4, o = s * 6;
    rIdx[o] = v; rIdx[o + 1] = v + 1; rIdx[o + 2] = v + 2; rIdx[o + 3] = v + 2; rIdx[o + 4] = v + 1; rIdx[o + 5] = v + 3;
  }
  const rg = new BufferGeometry();
  const aRPos = new BufferAttribute(rPos, 3).setUsage(DynamicDrawUsage);
  const aROff = new BufferAttribute(rOff, 2).setUsage(DynamicDrawUsage);
  const aRInfo = new BufferAttribute(rInfo, 4).setUsage(DynamicDrawUsage);
  rg.setAttribute('position', aRPos); rg.setAttribute('aOff', aROff); rg.setAttribute('aInfo', aRInfo);
  rg.setIndex(new BufferAttribute(rIdx, 1));
  const uLife = { value: 3 };
  const ribbons = new Mesh(rg, new ShaderMaterial({
    uniforms: { uTime, uLife, uClearAt, uStyle, uA, uB, uC },
    vertexShader: RIBBON_VS, fragmentShader: RIBBON_FS, ...additive,
  }));
  ribbons.frustumCulled = false; ribbons.renderOrder = 2;
  scene.add(ribbons);

  // Sparks: motion is analytic in the vertex shader, so the CPU only writes new births.
  const sPos = new Float32Array(SPARK_CAP * 3), sVel = new Float32Array(SPARK_CAP * 3), sMisc = new Float32Array(SPARK_CAP * 2);
  for (let i = 0; i < SPARK_CAP; i++) { sPos[i * 3 + 2] = -1e6; sVel[i * 3 + 2] = 1; }
  const sg = new BufferGeometry();
  const aSPos = new BufferAttribute(sPos, 3).setUsage(DynamicDrawUsage);
  const aSVel = new BufferAttribute(sVel, 3).setUsage(DynamicDrawUsage);
  const aSMisc = new BufferAttribute(sMisc, 2).setUsage(DynamicDrawUsage);
  sg.setAttribute('position', aSPos); sg.setAttribute('aVel', aSVel); sg.setAttribute('aMisc', aSMisc);
  const sparkU = {
    uTime, uDpr, uStyle, uA, uB, uC, uClearAt,
    uDrag: { value: 3 }, uSway: { value: 0 }, uGrav: { value: new Vector2() },
  };
  const sparks = new Points(sg, new ShaderMaterial({ uniforms: sparkU, vertexShader: SPARK_VS, fragmentShader: SPARK_FS, ...additive }));
  sparks.frustumCulled = false; sparks.renderOrder = 3;
  scene.add(sparks);

  // Reticle.
  const retU = {
    uTime, uA: { value: 0 }, uDown: { value: 0 }, uP: { value: 0 }, uArmed: { value: 0 },
    uC1: { value: new Color() }, uC2: { value: new Color() }, uArm: { value: new Color(0xffa63d) },
  };
  const reticle = new Mesh(new PlaneGeometry(1, 1), new ShaderMaterial({ uniforms: retU, vertexShader: RET_VS, fragmentShader: RET_FS, ...additive }));
  reticle.frustumCulled = false; reticle.renderOrder = 4; reticle.scale.set(120, 120, 1);
  scene.add(reticle);

  // Post: bloom into a half-float target with no depth buffer.
  const rt = new WebGLRenderTarget(W * dpr, H * dpr, { type: HalfFloatType, depthBuffer: false });
  const composer = new EffectComposer(renderer, rt);
  composer.addPass(new RenderPass(scene, camera));
  const bloom = new UnrealBloomPass(new Vector2(W, H), 1, 0.5, 0.1);
  composer.addPass(bloom);
  composer.addPass(new OutputPass());

  function resize() {
    W = innerWidth; H = innerHeight;
    renderer.setSize(W, H, false);
    composer.setSize(W, H);
    camera.right = W; camera.bottom = H; camera.updateProjectionMatrix();
    renderer.getDrawingBufferSize(bgU.uRes.value);
    dustU.uView.value.set(W, H);
  }
  addEventListener('resize', resize);
  resize();

  // ---------- State written from the queue ----------

  const t0 = performance.now();
  let look = LOOKS.neon;
  let read = queue.head;
  let segHead = 0, sDirty0 = Infinity, sDirty1 = -1;      // ribbon dirty segment range
  let pHead = 0, pDirty0 = Infinity, pDirty1 = -1;         // spark dirty range
  let ripHead = 0, lastRip = 0, lastActive = -99;
  let drawing = false, lx = 0, ly = 0, lb = 0, lp = 0, lw = 0, prevSeg = -1, pnx = 0, pny = 0, emitAcc = 0;
  let mx = 0, my = 0;                                       // smoothed ribbon point
  let retX = -9999, retY = -9999, retSeen = -99, retA = 0, retDown = 0, retP = 0;

  const halfW = (p) => (0.9 + 6.6 * Math.pow(p, 0.8)) * look.width;
  const rand = (a, b) => a + Math.random() * (b - a);

  function ripple(x, y, t, strength) {
    ripples[ripHead++ % RIPPLES].set(x, y, t, strength);
  }

  function spark(x, y, vx, vy, t) {
    const sp = look.spark, i = pHead++ % SPARK_CAP;
    sPos[i * 3] = x; sPos[i * 3 + 1] = y; sPos[i * 3 + 2] = t;
    sVel[i * 3] = vx; sVel[i * 3 + 1] = vy; sVel[i * 3 + 2] = rand(sp.l0, sp.l1);
    sMisc[i * 2] = rand(sp.s0, sp.s1); sMisc[i * 2 + 1] = Math.random();
    if (i < pDirty0) pDirty0 = i;
    if (i > pDirty1) pDirty1 = i;
  }

  function burst(x, y, p, t, n) {
    const sp = look.spark;
    for (let i = 0; i < n; i++) {
      const a = Math.random() * Math.PI * 2, v = rand(sp.v0, sp.v1) * (0.45 + 0.75 * p) * Math.sqrt(Math.random());
      spark(x, y, Math.cos(a) * v, Math.sin(a) * v - sp.lift * Math.random(), t);
    }
  }

  function setVert(v, cx, cy, ox, oy, birth, side, p, kill) {
    rPos[v * 3] = cx; rPos[v * 3 + 1] = cy; rPos[v * 3 + 2] = 0;
    rOff[v * 2] = ox; rOff[v * 2 + 1] = oy;
    rInfo[v * 4] = birth; rInfo[v * 4 + 1] = side; rInfo[v * 4 + 2] = p; rInfo[v * 4 + 3] = kill;
  }

  function dirtySeg(s) {
    if (s < sDirty0) sDirty0 = s;
    if (s > sDirty1) sDirty1 = s;
  }

  function ribbonTo(x, y, p, t) {
    const dx = x - lx, dy = y - ly, d = Math.hypot(dx, dy);
    if (d < 0.8) return 0;
    const nx = -dy / d, ny = dx / d, w = halfW(p);
    let ox = nx * lw, oy = ny * lw;
    if (prevSeg >= 0) {
      let jx = pnx + nx, jy = pny + ny;
      const jl = Math.hypot(jx, jy);
      if (jl > 0.5) {
        jx /= jl; jy /= jl;
        const sc = Math.min(2.2, 1 / Math.max(0.3, jx * nx + jy * ny));
        ox = jx * sc * lw; oy = jy * sc * lw;
        const v = prevSeg * 4 + 2;
        rOff[v * 2] = ox; rOff[v * 2 + 1] = oy; rOff[v * 2 + 2] = -ox; rOff[v * 2 + 3] = -oy;
        dirtySeg(prevSeg);
      }
    }
    const s = segHead++ % SEG_CAP, v = s * 4;
    setVert(v, lx, ly, ox, oy, lb, 1, lp, t);
    setVert(v + 1, lx, ly, -ox, -oy, lb, -1, lp, t);
    setVert(v + 2, x, y, nx * w, ny * w, t, 1, p, t);
    setVert(v + 3, x, y, -nx * w, -ny * w, t, -1, p, t);
    dirtySeg(s);
    prevSeg = s; pnx = nx; pny = ny; lx = x; ly = y; lb = t; lp = p; lw = w;
    return d;
  }

  function trail(x, y, rx, ry, p, t) {
    const fx0 = lx, fy0 = ly;
    mx += (x - mx) * 0.6; my += (y - my) * 0.6;
    const d = ribbonTo(mx, my, p, t);
    if (!d) return;
    const sp = look.spark, dir = Math.atan2(my - fy0, mx - fx0);
    emitAcc += d * sp.rate * (0.25 + 1.3 * p);
    while (emitAcc >= 1) {
      emitAcc -= 1;
      const back = dir + Math.PI + rand(-1.3, 1.3);
      const v = rand(sp.v0, sp.v1) * (0.35 + 0.65 * p) * Math.min(1.6, 0.5 + d * 0.08);
      spark(rx, ry, Math.cos(back) * v, Math.sin(back) * v - sp.lift * Math.random() * 0.5, t);
    }
    if (t - lastRip > 0.14) { ripple(x, y, t, 0.2 + 0.3 * p); lastRip = t; }
  }

  function drain() {
    const b = queue.buf, S = queue.stride, cap = queue.cap;
    let i = Math.max(read, queue.head - cap);
    for (; i < queue.head; i++) {
      const o = (i % cap) * S;
      const type = b[o], sx = b[o + 1], sy = b[o + 2], p = b[o + 3], rx = b[o + 4], ry = b[o + 5];
      const t = (b[o + 7] - t0) / 1000;
      lastActive = t;
      if (type === HOVER) {
        retX = rx; retY = ry; retSeen = t; retP = 0;
      } else if (type === DOWN) {
        drawing = true; lx = mx = sx; ly = my = sy; lb = t; lp = p; lw = halfW(p); prevSeg = -1; emitAcc = 0;
        burst(rx, ry, p, t, Math.round(look.spark.burst * (0.5 + p)));
        ripple(sx, sy, t, 1); lastRip = t;
        retX = rx; retY = ry; retSeen = t; retP = p;
      } else if (type === MOVE) {
        if (drawing) trail(sx, sy, rx, ry, p, t);
        retX = rx; retY = ry; retSeen = t; retP = p;
      } else if (type === UP) {
        if (drawing) burst(lx, ly, 0.2, t, 6);
        drawing = false; prevSeg = -1;
      } else if (type === LEAVE) {
        retSeen = -99;
      }
    }
    read = queue.head;
  }

  const ribbonAttrs = [aRPos, aROff, aRInfo], sparkAttrs = [aSPos, aSVel, aSMisc];

  // Upload only the touched slots; a ring wrap inside one frame simply widens the range to the whole buffer.
  function flush(attrs, lo, hi, per) {
    for (let i = 0; i < attrs.length; i++) {
      const a = attrs[i];
      a.clearUpdateRanges();
      a.addUpdateRange(lo * per * a.itemSize, (hi - lo + 1) * per * a.itemSize);
      a.needsUpdate = true;
    }
  }

  // ---------- Frame loop ----------

  let raf = 0, running = false, prevT = 0, skip = 0;

  function frame(now) {
    raf = requestAnimationFrame(frame);
    const t = (now - t0) / 1000, dt = Math.min(0.05, Math.max(0, t - prevT));
    prevT = t;
    drain();

    if (sDirty1 >= 0) { flush(ribbonAttrs, sDirty0, sDirty1, 4); sDirty0 = Infinity; sDirty1 = -1; }
    if (pDirty1 >= 0) { flush(sparkAttrs, pDirty0, pDirty1, 1); pDirty0 = Infinity; pDirty1 = -1; }

    // Reticle follows hover and contact, fades shortly after the pen leaves.
    const visible = drawing || t - retSeen < 0.18;
    retA += ((visible ? 1 : 0) - retA) * (1 - Math.exp(-dt * 14));
    retDown += ((drawing ? 1 : 0) - retDown) * (1 - Math.exp(-dt * 18));
    retU.uA.value = retA; retU.uDown.value = retDown;
    retU.uP.value += (retP - retU.uP.value) * (1 - Math.exp(-dt * 20));
    retU.uArmed.value += ((ui.rightArmed ? 1 : 0) - retU.uArmed.value) * (1 - Math.exp(-dt * 10));
    reticle.visible = retA > 0.01;
    reticle.position.set(retX, retY, 0);
    uHover.value.set(retX, retY, retA * (0.6 + 0.4 * retDown));

    const a = ui.area;
    bgU.uArea.value.set(a.x, a.y, a.w, a.h);
    uTime.value = t;

    // Idle: nothing alive and no pen, so the slow background only needs ~40 fps.
    if (!drawing && retA < 0.01 && t - lastActive > look.life + 1.5 && t - uClearAt.value > 0.5) {
      if (++skip % 3) return;
    }
    composer.render(dt);
  }

  function run(on) {
    if (on === running) return;
    running = on;
    if (on) { read = queue.head; prevT = (performance.now() - t0) / 1000; raf = requestAnimationFrame(frame); }
    else cancelAnimationFrame(raf);
  }

  function setStyle(name) {
    if (name === 'off' || !LOOKS[name]) { drawing = false; run(false); return; }
    look = LOOKS[name];
    uStyle.value = look.id;
    uA.value.set(look.a); uB.value.set(look.b); uC.value.set(look.c);
    bgU.uBgA.value.set(look.bgA); bgU.uBgB.value.set(look.bgB); bgU.uNeb.value.set(look.neb);
    bgU.uGrid.value.set(look.grid); bgU.uGridAmt.value = look.gridAmt;
    dustU.uDust.value.set(look.dust);
    retU.uC1.value.set(look.ret); retU.uC2.value.set(look.ret2);
    uLife.value = look.life;
    const sp = look.spark;
    sparkU.uDrag.value = sp.drag; sparkU.uSway.value = sp.sway; sparkU.uGrav.value.set(sp.gx, sp.gy);
    [bloom.strength, bloom.radius, bloom.threshold] = look.bloom;
    run(true);
  }

  function clear() {
    const t = (performance.now() - t0) / 1000;
    uClearAt.value = t;
    const a = ui.area;
    ripple(a.x + a.w / 2, a.y + a.h / 2, t, 1.6);
  }

  return { setStyle, clear };
}
