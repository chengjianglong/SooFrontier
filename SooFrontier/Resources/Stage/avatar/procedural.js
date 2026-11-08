// Built-in illustrated avatar drawn with Canvas 2D. Needs no assets and works
// everywhere; every feature (eyes, brows, lips, head) is driven by the animator and
// the live lipsync parameters.

import { Animator } from './animator.js';

export const HAIR_STYLES = ['long', 'short', 'bun', 'curly', 'bald'];

export class ProceduralAvatar {
  constructor(canvas, style) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.style = { skin: '#f2c6a5', hair: '#3b2219', hairStyle: 'long', eyes: '#5a3b24', shirt: '#e86f68', lips: '#c96a6a', ...style };
    this.anim = new Animator();
  }

  render(dt, mode, mouth) {
    const { canvas, ctx, style: s } = this;
    const a = this.anim.update(dt, mode, mouth);
    const W = canvas.width;
    const H = canvas.height;
    const R = Math.min(W * 0.95, H * 0.85) * 0.3;
    const cx = W / 2;
    const cy = H * 0.45;

    // Backdrop
    const bg = ctx.createRadialGradient(cx, cy - R * 0.3, R * 0.2, cx, cy, Math.max(W, H) * 0.8);
    bg.addColorStop(0, mix(s.shirt, '#ffffff', 0.78));
    bg.addColorStop(1, mix(s.shirt, '#1b1d2a', 0.55));
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, W, H);

    const hx = cx + a.headX * R * 3;
    const hy = cy + a.headY * R * 3;

    // Long hair behind shoulders
    if (s.hairStyle === 'long') {
      ctx.fillStyle = shade(s.hair, -0.1);
      ctx.beginPath();
      ctx.ellipse(hx, hy + R * 0.55, R * 1.08, R * 1.45, a.tilt * 0.5, 0, Math.PI * 2);
      ctx.fill();
    }

    // Torso + neck (breathing)
    const by = cy + R * 1.25 - a.breath * R * 0.02;
    ctx.fillStyle = skinShade(s.skin, -0.12);
    roundRect(ctx, cx - R * 0.28, cy + R * 0.55, R * 0.56, R * 0.85, R * 0.12);
    ctx.fill();
    const torso = ctx.createLinearGradient(0, by, 0, H);
    torso.addColorStop(0, s.shirt);
    torso.addColorStop(1, shade(s.shirt, -0.25));
    ctx.fillStyle = torso;
    ctx.beginPath();
    ctx.moveTo(cx - R * 1.9, H + 10);
    ctx.bezierCurveTo(cx - R * 1.8, by + R * 0.1, cx - R * 0.9, by - R * 0.05, cx - R * 0.35, by - R * 0.08);
    ctx.quadraticCurveTo(cx, by + R * 0.3, cx + R * 0.35, by - R * 0.08);
    ctx.bezierCurveTo(cx + R * 0.9, by - R * 0.05, cx + R * 1.8, by + R * 0.1, cx + R * 1.9, H + 10);
    ctx.closePath();
    ctx.fill();

    ctx.save();
    ctx.translate(hx, hy);
    ctx.rotate(a.tilt);

    // Hair volume behind head
    ctx.fillStyle = s.hair;
    if (s.hairStyle === 'bun') circle(ctx, 0, -R * 1.05, R * 0.38);
    if (s.hairStyle === 'curly') for (let i = 0; i < 14; i++) {
      const ang = Math.PI * (0.95 + (i / 13) * 1.1);
      circle(ctx, Math.cos(ang) * R * 0.95, Math.sin(ang) * R * 0.95 - R * 0.05, R * 0.3);
    }
    if (s.hairStyle !== 'bald') {
      ctx.beginPath();
      ctx.ellipse(0, -R * 0.12, R * 0.9, R * 0.98, 0, Math.PI, 0);
      ctx.fill();
    }

    // Ears
    ctx.fillStyle = skinShade(s.skin, -0.06);
    ctx.beginPath();
    ctx.ellipse(-R * 0.8, R * 0.02, R * 0.12, R * 0.2, -0.2, 0, Math.PI * 2);
    ctx.ellipse(R * 0.8, R * 0.02, R * 0.12, R * 0.2, 0.2, 0, Math.PI * 2);
    ctx.fill();

    // Face shape: rounded top, soft jaw that drops a little when the mouth opens.
    const jaw = mouth.open * R * 0.06;
    const face = ctx.createRadialGradient(-R * 0.25, -R * 0.3, R * 0.1, 0, 0, R * 1.1);
    face.addColorStop(0, skinShade(s.skin, 0.08));
    face.addColorStop(1, skinShade(s.skin, -0.08));
    ctx.fillStyle = face;
    ctx.beginPath();
    ctx.moveTo(-R * 0.8, -R * 0.1);
    ctx.bezierCurveTo(-R * 0.82, -R * 1.05, R * 0.82, -R * 1.05, R * 0.8, -R * 0.1);
    ctx.bezierCurveTo(R * 0.78, R * 0.45, R * 0.42, R * 0.86 + jaw, 0, R * 0.9 + jaw);
    ctx.bezierCurveTo(-R * 0.42, R * 0.86 + jaw, -R * 0.78, R * 0.45, -R * 0.8, -R * 0.1);
    ctx.fill();

    // Cheeks
    ctx.fillStyle = 'rgba(235, 110, 110, ' + (0.12 + a.smile * 0.1) + ')';
    ctx.beginPath();
    ctx.ellipse(-R * 0.45, R * 0.28, R * 0.15, R * 0.09, 0, 0, Math.PI * 2);
    ctx.ellipse(R * 0.45, R * 0.28, R * 0.15, R * 0.09, 0, 0, Math.PI * 2);
    ctx.fill();

    // Eyes
    for (const side of [-1, 1]) this.eye(side * R * 0.33, -R * 0.02, R, a, s);

    // Brows
    ctx.strokeStyle = shade(s.hair, -0.05);
    ctx.lineCap = 'round';
    ctx.lineWidth = R * 0.055;
    for (const side of [-1, 1]) {
      const bx = side * R * 0.33;
      const byy = -R * 0.25 - a.brow * R * 0.07 + a.blink * R * 0.015;
      ctx.beginPath();
      ctx.moveTo(bx - side * R * 0.15, byy + R * 0.03);
      ctx.quadraticCurveTo(bx, byy - R * 0.05, bx + side * R * 0.16, byy + R * 0.01);
      ctx.stroke();
    }

    // Nose
    ctx.strokeStyle = skinShade(s.skin, -0.22);
    ctx.lineWidth = R * 0.025;
    ctx.beginPath();
    ctx.moveTo(-R * 0.07, R * 0.24);
    ctx.quadraticCurveTo(0, R * 0.29, R * 0.07, R * 0.24);
    ctx.stroke();

    this.mouth(0, R * 0.47 + jaw * 0.5, R, mouth, a, s);

    // Front hair / bangs
    ctx.fillStyle = s.hair;
    if (s.hairStyle === 'long' || s.hairStyle === 'bun') {
      ctx.beginPath();
      ctx.moveTo(-R * 0.86, -R * 0.05);
      ctx.bezierCurveTo(-R * 0.9, -R * 1.1, R * 0.9, -R * 1.1, R * 0.86, -R * 0.05);
      ctx.bezierCurveTo(R * 0.75, -R * 0.55, R * 0.3, -R * 0.62, -R * 0.05, -R * 0.55);
      ctx.bezierCurveTo(-R * 0.4, -R * 0.62, -R * 0.75, -R * 0.45, -R * 0.86, -R * 0.05);
      ctx.fill();
    } else if (s.hairStyle === 'short' || s.hairStyle === 'curly') {
      ctx.beginPath();
      ctx.moveTo(-R * 0.84, -R * 0.2);
      ctx.bezierCurveTo(-R * 0.9, -R * 1.12, R * 0.9, -R * 1.12, R * 0.84, -R * 0.2);
      ctx.bezierCurveTo(R * 0.7, -R * 0.55, R * 0.2, -R * 0.75, -R * 0.3, -R * 0.62);
      ctx.bezierCurveTo(-R * 0.6, -R * 0.58, -R * 0.78, -R * 0.45, -R * 0.84, -R * 0.2);
      ctx.fill();
    }
    ctx.restore();
  }

  eye(x, y, R, a, s) {
    const ctx = this.ctx;
    const w = R * 0.17;
    const h = R * 0.11;
    const almond = () => {
      ctx.beginPath();
      ctx.moveTo(x - w, y);
      ctx.bezierCurveTo(x - w * 0.5, y - h * 1.25, x + w * 0.5, y - h * 1.25, x + w, y);
      ctx.bezierCurveTo(x + w * 0.5, y + h * 0.95, x - w * 0.5, y + h * 0.95, x - w, y);
      ctx.closePath();
    };
    ctx.save();
    almond();
    ctx.fillStyle = '#fbfaf7';
    ctx.fill();
    ctx.clip();
    const ix = x + a.gazeX * w * 0.55;
    const iy = y + a.gazeY * h * 0.6;
    ctx.fillStyle = s.eyes;
    circle(ctx, ix, iy, h * 0.82);
    ctx.fillStyle = '#111';
    circle(ctx, ix, iy, h * 0.4);
    ctx.fillStyle = 'rgba(255,255,255,0.9)';
    circle(ctx, ix + h * 0.25, iy - h * 0.3, h * 0.17);
    // Upper eyelid sweeping down on blink
    const lid = -h * 1.3 + (h * 2.4) * Math.min(1, a.blink * 1.05);
    ctx.fillStyle = skinShade(s.skin, -0.04);
    ctx.fillRect(x - w * 1.2, y - h * 2, w * 2.4, h * 0.7 + lid + h);
    ctx.restore();
    // Lash line
    ctx.strokeStyle = '#1d1512';
    ctx.lineWidth = R * 0.028;
    ctx.lineCap = 'round';
    ctx.beginPath();
    const ly = y + (h * 1.0) * Math.min(1, a.blink * 1.05);
    ctx.moveTo(x - w * 1.05, y + R * 0.005);
    ctx.quadraticCurveTo(x, ly - h * 1.25 * (1 - a.blink), x + w * 1.05, y + R * 0.005);
    ctx.stroke();
  }

  mouth(x, y, R, m, a, s) {
    const ctx = this.ctx;
    const smile = a.smile * (1 - m.open * 0.6);
    const w = R * 0.21 * (1 + 0.28 * m.wide - 0.32 * m.round + 0.12 * smile);
    const open = R * (0.012 + m.open * 0.2 * (1 - 0.35 * m.wide) + m.round * m.open * 0.05);
    const lift = smile * R * 0.05;
    const upTop = y - R * 0.035;
    const lowBottom = y + open + R * 0.04;

    if (open > R * 0.03) {
      // Mouth interior with teeth and tongue
      ctx.save();
      ctx.beginPath();
      ctx.moveTo(x - w, y - lift);
      ctx.quadraticCurveTo(x, y - R * 0.01, x + w, y - lift);
      ctx.quadraticCurveTo(x, y + open * 1.25, x - w, y - lift);
      ctx.closePath();
      ctx.fillStyle = '#3a0f14';
      ctx.fill();
      ctx.clip();
      ctx.fillStyle = '#f6f2ea';
      ctx.fillRect(x - w, y - R * 0.02, w * 2, Math.min(open * 0.35, R * 0.05));
      ctx.fillStyle = '#c4535e';
      ctx.beginPath();
      ctx.ellipse(x, y + open * 1.05, w * 0.6, open * 0.4, 0, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }

    // Lips
    ctx.fillStyle = s.lips;
    ctx.beginPath(); // upper lip with cupid's bow
    ctx.moveTo(x - w, y - lift);
    ctx.bezierCurveTo(x - w * 0.6, upTop, x - w * 0.25, upTop - R * 0.01, x, upTop + R * 0.008);
    ctx.bezierCurveTo(x + w * 0.25, upTop - R * 0.01, x + w * 0.6, upTop, x + w, y - lift);
    ctx.quadraticCurveTo(x, y + R * 0.004, x - w, y - lift);
    ctx.fill();
    ctx.fillStyle = shade(s.lips, 0.06);
    ctx.beginPath(); // lower lip
    ctx.moveTo(x - w, y - lift);
    ctx.quadraticCurveTo(x, y + open * 1.25, x + w, y - lift);
    ctx.quadraticCurveTo(x + w * 0.5, lowBottom, x, lowBottom);
    ctx.quadraticCurveTo(x - w * 0.5, lowBottom, x - w, y - lift);
    ctx.fill();
  }

  destroy() {}
}

function circle(ctx, x, y, r) {
  ctx.beginPath();
  ctx.arc(x, y, r, 0, Math.PI * 2);
  ctx.fill();
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.roundRect ? ctx.roundRect(x, y, w, h, r) : ctx.rect(x, y, w, h);
}

function hex(c) {
  const n = parseInt(c.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}
function toHex([r, g, b]) {
  return '#' + [r, g, b].map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')).join('');
}
export function mix(a, b, t) {
  const x = hex(a), y = hex(b);
  return toHex(x.map((v, i) => v + (y[i] - v) * t));
}
function shade(c, amt) {
  return amt >= 0 ? mix(c, '#ffffff', amt) : mix(c, '#000000', -amt);
}
function skinShade(c, amt) {
  return amt >= 0 ? mix(c, '#fff4ec', amt) : mix(c, '#5a2a1a', -amt);
}
