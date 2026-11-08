// Shared "aliveness" for every avatar: blinking, eye saccades, head sway, nods and
// brow raises, adapted to whether the avatar is idle, listening, thinking or talking.

export class Animator {
  constructor(seed = Math.random() * 1000) {
    this.t = seed;
    this.nextBlink = 1 + Math.random() * 3;
    this.blinkT = -1;
    this.doubleBlink = false;
    this.gaze = { x: 0, y: 0, tx: 0, ty: 0, next: 0 };
    this.brow = 0;
    this.browTarget = 0;
    this.nextBrow = 2;
    this.smile = 0.3;
  }

  update(dt, mode, mouth) {
    this.t += dt;
    const t = this.t;

    // Blink: quick close/open, sometimes twice.
    this.nextBlink -= dt;
    if (this.nextBlink <= 0 && this.blinkT < 0) {
      this.blinkT = 0;
      this.doubleBlink = Math.random() < 0.15;
      this.nextBlink = 2 + Math.random() * 4;
    }
    let blink = 0;
    if (this.blinkT >= 0) {
      this.blinkT += dt;
      const d = 0.16;
      blink = Math.sin(Math.min(1, this.blinkT / d) * Math.PI);
      if (this.blinkT >= d) {
        if (this.doubleBlink) {
          this.doubleBlink = false;
          this.blinkT = -0.08;
          this.nextBlink = 0.08;
        } else this.blinkT = -1;
      }
    }

    // Gaze: small saccades; look at the user while listening, away while thinking.
    const g = this.gaze;
    if (t > g.next) {
      const spread = mode === 'listening' ? 0.25 : mode === 'thinking' ? 0.5 : 0.45;
      g.tx = (Math.random() - 0.5) * spread;
      g.ty = (Math.random() - 0.5) * spread * 0.6;
      if (mode === 'thinking') {
        g.tx = (Math.random() < 0.5 ? -1 : 1) * (0.4 + Math.random() * 0.3);
        g.ty = -0.35;
      }
      g.next = t + (mode === 'speaking' ? 0.6 + Math.random() * 1.4 : 1 + Math.random() * 2.5);
    }
    g.x += (g.tx - g.x) * Math.min(1, dt * 18);
    g.y += (g.ty - g.y) * Math.min(1, dt * 18);

    // Head: layered slow sines, livelier and nodding with speech energy.
    const talk = mode === 'speaking' ? 1 : 0;
    const e = mouth?.energy || 0;
    const tilt = Math.sin(t * 0.7) * 0.025 + Math.sin(t * 1.9 + 1) * 0.01 + talk * Math.sin(t * 2.6) * 0.02 + (mode === 'listening' ? 0.03 : 0);
    const headX = Math.sin(t * 0.5 + 2) * 0.012 + talk * Math.sin(t * 1.7) * 0.012;
    const headY = Math.sin(t * 0.9) * 0.006 + talk * e * 0.025 + Math.sin(t * 0.35) * 0.004;

    // Brows: raise on emphasis while talking, a little while thinking.
    this.nextBrow -= dt;
    if (this.nextBrow <= 0) {
      this.browTarget = talk && e > 0.3 ? 0.6 + Math.random() * 0.4 : mode === 'thinking' ? 0.5 : 0;
      this.nextBrow = 0.4 + Math.random() * 1.8;
      setTimeout(() => (this.browTarget = 0), 350 + Math.random() * 400);
    }
    this.brow += (this.browTarget - this.brow) * Math.min(1, dt * 10);

    const smileTarget = mode === 'listening' ? 0.55 : mode === 'speaking' ? 0.3 : 0.35;
    this.smile += (smileTarget - this.smile) * Math.min(1, dt * 3);
    const breath = Math.sin(t * 1.6) * 0.5 + 0.5;

    return { blink, gazeX: g.x, gazeY: g.y, tilt, headX, headY, brow: this.brow, smile: this.smile, breath };
  }
}
