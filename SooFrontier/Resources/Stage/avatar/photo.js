// Photo avatar: turns any uploaded portrait (photo, painting, cartoon) into a talking
// face. The 478 MediaPipe face landmarks found at upload time, plus a ring of helper
// points and the image border, are triangulated into a mesh textured with the
// image. Each frame the mesh is warped: the jaw and lower lip drop with the audio,
// lips widen or round, upper eyelids slide down to blink, brows lift, irises follow
// the gaze and the whole head sways. A drawn mouth interior (with teeth) shows
// through the hole between the lips.

import Delaunator from '/vendor/delaunator/index.js';
import { Animator } from './animator.js';

const INNER_LIP = [78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308, 324, 318, 402, 317, 14, 87, 178, 88, 95];
const UPPER_INNER = [191, 80, 81, 82, 13, 312, 311, 310, 415];
const LOWER_INNER = [324, 318, 402, 317, 14, 87, 178, 88, 95];
const UPPER_TEETH_PATH = [78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308];
const FACE_OVAL = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109];
const EYES = [
  { up: [246, 161, 160, 159, 158, 157, 173], low: [7, 163, 144, 145, 153, 154, 155], corners: [33, 133], brow: [70, 63, 105, 66, 107, 46, 53, 52, 65, 55] },
  { up: [466, 388, 387, 386, 385, 384, 398], low: [249, 390, 373, 374, 380, 381, 382], corners: [263, 362], brow: [300, 293, 334, 296, 336, 276, 283, 282, 295, 285] },
];
const IRIS = [468, 469, 470, 471, 472, 473, 474, 475, 476, 477];

const VS = `attribute vec2 a_pos; attribute vec2 a_uv; uniform vec4 u_view; varying vec2 v_uv;
void main(){ vec2 p=(a_pos-u_view.xy)/u_view.zw; gl_Position=vec4(p.x*2.0-1.0,1.0-p.y*2.0,0.0,1.0); v_uv=a_uv; }`;
const FS = `precision mediump float; uniform sampler2D u_tex; varying vec2 v_uv;
void main(){ gl_FragColor=texture2D(u_tex,v_uv); }`;
const VS_SOLID = `attribute vec2 a_pos; attribute vec4 a_col; uniform vec4 u_view; varying vec4 v_col;
void main(){ vec2 p=(a_pos-u_view.xy)/u_view.zw; gl_Position=vec4(p.x*2.0-1.0,1.0-p.y*2.0,0.0,1.0); v_col=a_col; }`;
const FS_SOLID = `precision mediump float; varying vec4 v_col; void main(){ gl_FragColor=v_col; }`;
const TEETH = [0.86, 0.83, 0.77, 1];
const MOUTH_DEEP = [0.07, 0.02, 0.03, 1];
const MOUTH_RIM = [0.3, 0.11, 0.12, 1];
const mixColor = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);

export class PhotoAvatar {
  constructor(canvas, { src, landmarks, width, height }) {
    this.canvas = canvas;
    this.anim = new Animator();
    const gl = canvas.getContext('webgl', { stencil: true, premultipliedAlpha: false, antialias: true });
    if (!gl) throw new Error('WebGL is not available');
    this.gl = gl;
    this.tex = program(gl, VS, FS);
    this.solid = program(gl, VS_SOLID, FS_SOLID);
    this.buildMesh(landmarks, width, height);
    this.ready = false;
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => {
      this.texture = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, this.texture);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
      this.ready = true;
    };
    img.onerror = () => (this.failed = true);
    img.src = src;
  }

  buildMesh(landmarks, W, H) {
    const P = landmarks.map(([x, y]) => [x * W, y * H]);
    const v = (i) => P[i];
    const sub = (a, b) => [a[0] - b[0], a[1] - b[1]];
    const len = (a) => Math.hypot(a[0], a[1]);
    const dot = (a, b) => a[0] * b[0] + a[1] * b[1];

    // Face frame
    const top = v(10), chin = v(152);
    const faceH = len(sub(chin, top));
    const down = sub(chin, top).map((c) => c / faceH);
    const right = [-down[1], down[0]];
    const M = [(v(13)[0] + v(14)[0]) / 2, (v(13)[1] + v(14)[1]) / 2];
    const mouthW = len(sub(v(291), v(61)));
    const chinRy = dot(sub(chin, M), down);
    const center = FACE_OVAL.reduce((c, i) => [c[0] + v(i)[0] / FACE_OVAL.length, c[1] + v(i)[1] / FACE_OVAL.length], [0, 0]);
    this.frame = { down, right, M, faceH, mouthW, chin };

    // Helper points: two rings around the face (for smooth falloff) and the image border.
    const pts = P.map((p) => [...p]);
    const headW = P.map(() => 1);
    const clampPt = ([x, y]) => [Math.min(W, Math.max(0, x)), Math.min(H, Math.max(0, y))];
    for (const [scale, w] of [[1.3, 0.7], [1.75, 0.3]]) {
      for (const i of FACE_OVAL) {
        const p = v(i);
        pts.push(clampPt([center[0] + (p[0] - center[0]) * scale, center[1] + (p[1] - center[1]) * scale]));
        headW.push(w);
      }
    }
    const n = 8;
    for (let k = 0; k <= n; k++) {
      for (const p of [[(W * k) / n, 0], [(W * k) / n, H], [0, (H * k) / n], [W, (H * k) / n]]) {
        pts.push(p);
        headW.push(0);
      }
    }
    this.rest = pts;
    this.headW = headW;
    this.uv = new Float32Array(pts.flatMap(([x, y]) => [x / W, y / H]));

    // Per-vertex deformation weights
    const N = pts.length;
    const jaw = new Float32Array(N), lipX = new Float32Array(N), smileW = new Float32Array(N);
    const upper = new Set(UPPER_INNER), lower = new Set(LOWER_INNER);
    // Lip line: parabola through both mouth corners and the mouth centre (origin).
    const cL = dot(sub(v(78), M), right), cR = dot(sub(v(308), M), right);
    const yL = dot(sub(v(78), M), down), yR = dot(sub(v(308), M), down);
    const slitAt = (rx) => {
      const x = Math.min(Math.max(rx, Math.min(cL, cR)), Math.max(cL, cR));
      return (yL * x * (x - cR)) / (cL * (cL - cR) || 1) + (yR * x * (x - cL)) / (cR * (cR - cL) || 1);
    };
    for (let i = 0; i < N; i++) {
      if (headW[i] === 0) continue;
      const rel = sub(pts[i], M);
      const rx = dot(rel, right), ry = dot(rel, down);
      const below = lower.has(i) || (!upper.has(i) && ry > slitAt(rx) + 0.002 * faceH);
      const lipShape = Math.pow(Math.max(0, 1 - (rx / (0.55 * mouthW)) ** 2), 0.7);
      const b = smoothstep(0, 0.12 * faceH, ry);
      const jawRigid = Math.exp(-((rx / (0.95 * mouthW)) ** 2)) * (1 - smoothstep(chinRy, chinRy * 1.5, ry));
      if (below) jaw[i] = lipShape * (1 - b) + jawRigid * b;
      else jaw[i] = -0.12 * lipShape * (1 - smoothstep(0, 0.08 * faceH, -ry));
      if (i === 78 || i === 308 || i === 61 || i === 291) jaw[i] = 0.25;
      lipX[i] = Math.exp(-((rx / (0.8 * mouthW)) ** 2 + (ry / (0.12 * faceH)) ** 2));
      smileW[i] = Math.exp(-(((Math.abs(rx) - 0.5 * mouthW) / (0.2 * mouthW)) ** 2 + (ry / (0.07 * faceH)) ** 2));
    }
    this.w = { jaw, lipX, smileW };

    // Eyes: blink pairs and falloff weights for the skin above each eye.
    this.eyes = EYES.map((e) => {
      const ew = len(sub(v(e.corners[0]), v(e.corners[1])));
      const pts2 = [...e.up, ...e.low].map(v);
      const c = pts2.reduce((s, p) => [s[0] + p[0] / pts2.length, s[1] + p[1] / pts2.length], [0, 0]);
      const eh = Math.max(len(sub(v(e.up[3]), v(e.low[3]))), ew * 0.18);
      const lid = new Float32Array(N), brow = new Float32Array(N);
      const browC = e.brow.map(v).reduce((s, p) => [s[0] + p[0] / e.brow.length, s[1] + p[1] / e.brow.length], [0, 0]);
      const skip = new Set([...e.up, ...e.low, ...e.corners]);
      for (let i = 0; i < N; i++) {
        if (headW[i] === 0 || skip.has(i)) continue;
        const rel = sub(pts[i], c);
        const ry = dot(rel, down);
        const r = len(rel);
        if (IRIS.includes(i) && r < ew * 0.6) lid[i] = 0.45;
        else if (ry < -eh * 0.3 && r < ew * 1.6) lid[i] = Math.exp(-((r / (0.65 * ew)) ** 2));
        const rb = len(sub(pts[i], browC));
        if (ry < -eh * 0.2) brow[i] = Math.exp(-((rb / (1.0 * ew)) ** 2));
      }
      return { ...e, ew, eh, c, lid, brow };
    });
    this.irisSet = IRIS.filter((i) => i < P.length);

    // Triangulate in a "mouth open" pose so the lip hole gets its own triangles.
    const open = pts.map((p, i) => [p[0] + down[0] * jaw[i] * faceH * 0.12, p[1] + down[1] * jaw[i] * faceH * 0.12]);
    const tri = new Delaunator(open.flat()).triangles;
    const inner = new Set(INNER_LIP);
    const keep = [];
    for (let t = 0; t < tri.length; t += 3) {
      if (inner.has(tri[t]) && inner.has(tri[t + 1]) && inner.has(tri[t + 2])) continue;
      keep.push(tri[t], tri[t + 1], tri[t + 2]);
    }
    const gl = this.gl;
    this.count = keep.length;
    this.ibo = gl.createBuffer();
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.ibo);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint16Array(keep), gl.STATIC_DRAW);
    this.uvBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.uvBuf);
    gl.bufferData(gl.ARRAY_BUFFER, this.uv, gl.STATIC_DRAW);
    this.pos = new Float32Array(N * 2);
    this.posBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.posBuf);
    gl.bufferData(gl.ARRAY_BUFFER, this.pos, gl.DYNAMIC_DRAW);
    this.solidBuf = gl.createBuffer();

    // Camera: frame the head and shoulders.
    const xs = FACE_OVAL.map((i) => v(i)[0]), ys = FACE_OVAL.map((i) => v(i)[1]);
    this.faceBox = { x0: Math.min(...xs), x1: Math.max(...xs), y0: Math.min(...ys), y1: Math.max(...ys) };
    this.imgW = W;
    this.imgH = H;
  }

  view() {
    const { canvas, faceBox: b, imgW, imgH } = this;
    const aspect = canvas.width / canvas.height;
    const fw = b.x1 - b.x0, fh = b.y1 - b.y0;
    let h = Math.max(fh * 2.1, (fw * 2.1) / aspect);
    h = Math.min(h, imgH, imgW / aspect);
    const w = h * aspect;
    const cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2 + fh * 0.12;
    const x = Math.min(Math.max(cx - w / 2, 0), Math.max(0, imgW - w));
    const y = Math.min(Math.max(cy - h / 2, 0), Math.max(0, imgH - h));
    return [x, y, w, h];
  }

  render(dt, mode, mouth) {
    const gl = this.gl;
    const a = this.anim.update(dt, mode, mouth);
    gl.viewport(0, 0, this.canvas.width, this.canvas.height);
    gl.clearColor(0.08, 0.08, 0.1, 1);
    gl.clearStencil(0);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);
    if (!this.ready) return;

    const { rest, pos, headW, w, frame: f } = this;
    const { down, right, faceH, mouthW } = f;
    const d = mouth.open * faceH * 0.085;
    const lipScale = 0.16 * mouth.wide - 0.22 * mouth.round;
    const smile = a.smile * 0.5 * (1 - mouth.open);
    const N = rest.length;

    // Expression
    for (let i = 0; i < N; i++) {
      let x = rest[i][0], y = rest[i][1];
      if (headW[i] > 0) {
        const jd = w.jaw[i] * d;
        x += down[0] * jd;
        y += down[1] * jd;
        const rx = (x - f.M[0]) * right[0] + (y - f.M[1]) * right[1];
        const sx = rx * lipScale * w.lipX[i];
        x += right[0] * sx;
        y += right[1] * sx;
        const sm = -smile * faceH * 0.012 * w.smileW[i];
        x += down[0] * sm;
        y += down[1] * sm;
      }
      pos[i * 2] = x;
      pos[i * 2 + 1] = y;
    }
    for (const e of this.eyes) {
      const k = a.blink * 0.92;
      for (let j = 0; j < e.up.length; j++) {
        const u = e.up[j], l = e.low[j];
        pos[u * 2] += (rest[l][0] - rest[u][0]) * k;
        pos[u * 2 + 1] += (rest[l][1] - rest[u][1]) * k;
      }
      const lift = a.brow * faceH * 0.018;
      for (let i = 0; i < N; i++) {
        const lw = e.lid[i] * e.eh * k, bw = e.brow[i] * lift;
        if (!lw && !bw) continue;
        pos[i * 2] += down[0] * (lw - bw);
        pos[i * 2 + 1] += down[1] * (lw - bw);
      }
    }
    const gx = a.gazeX * this.eyes[0].ew * 0.1, gy = a.gazeY * this.eyes[0].eh * 0.25;
    for (const i of this.irisSet) {
      pos[i * 2] += right[0] * gx + down[0] * gy;
      pos[i * 2 + 1] += right[1] * gx + down[1] * gy;
    }

    // Head sway around a pivot under the chin
    const piv = [f.chin[0] + down[0] * faceH * 0.15, f.chin[1] + down[1] * faceH * 0.15];
    const tx = a.headX * faceH * 0.6, ty = a.headY * faceH * 0.6;
    for (let i = 0; i < N; i++) {
      const hw = headW[i];
      if (!hw) continue;
      const ang = a.tilt * 0.6 * hw;
      const c = Math.cos(ang), s = Math.sin(ang);
      const px = pos[i * 2] - piv[0], py = pos[i * 2 + 1] - piv[1];
      pos[i * 2] = piv[0] + px * c - py * s + tx * hw;
      pos[i * 2 + 1] = piv[1] + px * s + py * c + ty * hw;
    }

    const view = this.view();

    // 1. Mouth interior into the stencil
    const at = (i) => [pos[i * 2], pos[i * 2 + 1]];
    const loop = INNER_LIP.map(at);
    const cen = loop.reduce((s, p) => [s[0] + p[0] / loop.length, s[1] + p[1] / loop.length], [0, 0]);
    gl.enable(gl.STENCIL_TEST);
    gl.stencilFunc(gl.ALWAYS, 1, 0xff);
    gl.stencilOp(gl.KEEP, gl.KEEP, gl.REPLACE);
    this.drawSolid([cen, ...loop, loop[0]], gl.TRIANGLE_FAN, [MOUTH_DEEP, ...loop.map(() => MOUTH_RIM), MOUTH_RIM], view);
    gl.stencilFunc(gl.EQUAL, 1, 0xff);
    gl.stencilOp(gl.KEEP, gl.KEEP, gl.KEEP);
    // tongue
    const low = at(14);
    const tongue = [];
    for (let k = 0; k <= 20; k++) {
      const ang = (k / 20) * Math.PI * 2;
      tongue.push([low[0] + Math.cos(ang) * mouthW * 0.28, low[1] + Math.sin(ang) * mouthW * 0.12]);
    }
    const tongueEdge = [0.42, 0.17, 0.19, 1];
    this.drawSolid([low, ...tongue], gl.TRIANGLE_FAN, [[0.55, 0.26, 0.28, 1], ...tongue.map(() => tongueEdge)], view);
    // Upper teeth: show more as the mouth opens, shaded under the lip and toward the corners.
    const gap = Math.hypot(at(14)[0] - at(13)[0], at(14)[1] - at(13)[1]);
    const toothH = Math.min(mouthW * 0.1, gap * 0.5);
    const strip = [];
    const colors = [];
    const last = UPPER_TEETH_PATH.length - 1;
    UPPER_TEETH_PATH.forEach((i, j) => {
      const p = at(i);
      const side = Math.abs(j - last / 2) / (last / 2);
      strip.push([p[0] - down[0] * toothH * 0.4, p[1] - down[1] * toothH * 0.4], [p[0] + down[0] * toothH, p[1] + down[1] * toothH]);
      colors.push(mixColor(TEETH, MOUTH_DEEP, 0.35 + side * 0.55), mixColor(TEETH, MOUTH_DEEP, 0.08 + side ** 2 * 0.8));
    });
    this.drawSolid(strip, gl.TRIANGLE_STRIP, colors, view);
    gl.disable(gl.STENCIL_TEST);

    // 2. Textured face mesh with the lip hole left open
    gl.useProgram(this.tex.prog);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.posBuf);
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, pos);
    gl.enableVertexAttribArray(this.tex.a_pos);
    gl.vertexAttribPointer(this.tex.a_pos, 2, gl.FLOAT, false, 0, 0);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.uvBuf);
    gl.enableVertexAttribArray(this.tex.a_uv);
    gl.vertexAttribPointer(this.tex.a_uv, 2, gl.FLOAT, false, 0, 0);
    gl.uniform4fv(this.tex.u_view, view);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.texture);
    gl.uniform1i(this.tex.u_tex, 0);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.ibo);
    gl.drawElements(gl.TRIANGLES, this.count, gl.UNSIGNED_SHORT, 0);
    gl.disableVertexAttribArray(this.tex.a_uv);
  }

  // colors: one RGBA per point
  drawSolid(points, mode, colors, view) {
    const gl = this.gl;
    gl.useProgram(this.solid.prog);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.solidBuf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(points.flatMap((p, i) => [...p, ...colors[i]])), gl.STREAM_DRAW);
    gl.enableVertexAttribArray(this.solid.a_pos);
    gl.vertexAttribPointer(this.solid.a_pos, 2, gl.FLOAT, false, 24, 0);
    gl.enableVertexAttribArray(this.solid.a_col);
    gl.vertexAttribPointer(this.solid.a_col, 4, gl.FLOAT, false, 24, 8);
    gl.uniform4fv(this.solid.u_view, view);
    gl.drawArrays(mode, 0, points.length);
    gl.disableVertexAttribArray(this.solid.a_col);
  }

  destroy() {
    this.gl.getExtension('WEBGL_lose_context')?.loseContext();
  }
}

function smoothstep(a, b, x) {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
}

function program(gl, vs, fs) {
  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const prog = gl.createProgram();
  gl.attachShader(prog, compile(gl.VERTEX_SHADER, vs));
  gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, fs));
  gl.linkProgram(prog);
  const loc = (n) => gl.getAttribLocation(prog, n);
  const uni = (n) => gl.getUniformLocation(prog, n);
  return { prog, a_pos: loc('a_pos'), a_uv: loc('a_uv'), a_col: loc('a_col'), u_view: uni('u_view'), u_tex: uni('u_tex') };
}
