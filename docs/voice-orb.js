// Reusable <voice-orb> web component — self-contained canvas orb with tunable params.
class VoiceOrb extends HTMLElement {
  constructor() {
    super();
    this._shadow = this.attachShadow({ mode: 'open' });
    this._canvas = document.createElement('canvas');
    this._canvas.style.width = '100%';
    this._canvas.style.height = '100%';
    this._canvas.style.display = 'block';
    this._shadow.appendChild(this._canvas);
    this._ctx = this._canvas.getContext('2d');
    this._dots = null;
    this._dotsN = 0;
    this._raf = null;
    this._t0 = performance.now();
  }
  static get observedAttributes() { return ['mood','hue','spin','gain','pulse','dots','wrap','history','colorby']; }
  connectedCallback() {
    this._sizeCanvas();
    this._ensureDots();
    this._loop();
    window.addEventListener('resize', this._sizeCanvas.bind(this));
  }
  disconnectedCallback() {
    if (this._raf) cancelAnimationFrame(this._raf);
    window.removeEventListener('resize', this._sizeCanvas.bind(this));
  }
  attributeChangedCallback() { this._ensureDots(); }
  _sizeCanvas() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = this.clientWidth || 240, h = this.clientHeight || 240;
    if (this._canvas.width !== Math.round(w*dpr) || this._canvas.height !== Math.round(h*dpr)) {
      this._canvas.width = Math.round(w*dpr); this._canvas.height = Math.round(h*dpr);
    }
    this._ctx.setTransform(dpr,0,0,dpr,0,0);
    this._w = w; this._h = h;
  }
  _params() {
    const mood = this.getAttribute('mood') || 'neutral';
    const MOODS = {
      listening: { hue: 172, spin: 0.35, gain: 0.75, pulse: 0 },
      done:      { hue: 140, spin: 0.05, gain: 0.25, pulse: 0 },
      error:     { hue: 0,   spin: 0.0,  gain: 1.0,  pulse: 1 },
      neutral:   { hue: 220, spin: 0.12, gain: 0.5,  pulse: 0 },
    };
    const base = MOODS[mood] || MOODS.neutral;
    const hue = this.hasAttribute('hue') ? parseFloat(this.getAttribute('hue')) : base.hue;
    const spin = this.hasAttribute('spin') ? parseFloat(this.getAttribute('spin')) : base.spin;
    const gain = this.hasAttribute('gain') ? parseFloat(this.getAttribute('gain')) : base.gain;
    const pulse = this.hasAttribute('pulse') ? parseFloat(this.getAttribute('pulse')) : base.pulse;
    const wrap = this.hasAttribute('wrap') ? parseFloat(this.getAttribute('wrap')) : 1;
    const history = this.hasAttribute('history') ? parseFloat(this.getAttribute('history')) : 0.8;
    const colorby = this.getAttribute('colorby') || 'none';
    return { hue, spin, gain, pulse, wrap, history, colorby };
  }
  _ensureDots() {
    const n = parseInt(this.getAttribute('dots') || '1400', 10);
    if (this._dots && this._dotsN === n) return;
    this._dotsN = n;
    const d = { ux:new Float32Array(n), uy:new Float32Array(n), uz:new Float32Array(n),
                age:new Float32Array(n), pitch:new Float32Array(n),
                fx:new Float32Array(n), fy:new Float32Array(n) };
    const golden = Math.PI * (3 - Math.sqrt(5));
    for (let i=0;i<n;i++){
      const y = 1 - (2*(i+0.5))/n, r = Math.sqrt(1-y*y), a = golden*i;
      d.ux[i]=Math.cos(a)*r; d.uy[i]=y; d.uz[i]=Math.sin(a)*r;
      d.age[i]=Math.abs(Math.asin(y))/(Math.PI/2);
      d.pitch[i]=Math.abs(Math.atan2(Math.sin(a), Math.cos(a)))/Math.PI;
      d.fx[i] = (Math.atan2(Math.sin(a), Math.cos(a)) / Math.PI) * 1.35;
      d.fy[i] = (Math.asin(y) / (Math.PI/2)) * 0.95;
    }
    this._dots = d;
  }
  _loop() {
    const render = () => { this._draw(); this._raf = requestAnimationFrame(render); };
    this._raf = requestAnimationFrame(render);
  }
  _draw() {
    const ctx = this._ctx;
    const w = this._w, h = this._h;
    if (!w || !h) return;
    const { hue, spin, gain, pulse, wrap, history, colorby } = this._params();
    const t = (performance.now() - this._t0)/1000;
    let v = pulse ? (0.5 + 0.5*Math.sin(t*8)) : (0.35 + 0.25*Math.sin(t*1.7) + 0.15*Math.sin(t*3.1));
    ctx.clearRect(0,0,w,h);
    const cx = w/2, cy = h/2;
    const R = Math.min(w,h)/2 * 0.82;
    const spinA = spin * t;
    const sy = Math.sin(spinA), cyr = Math.cos(spinA);
    const tip = 0.45;
    const sx = Math.sin(tip), cxt = Math.cos(tip);
    const d = this._dots;
    const n = d.ux.length;
    const layers = [new Path2D(), new Path2D(), new Path2D(), new Path2D()];
    for (let i=0;i<n;i++){
      const ux=d.ux[i], uy=d.uy[i], uz=d.uz[i];
      const age=d.age[i], pitch=d.pitch[i];
      const out = gain * v * (0.6 + 0.4*Math.sin(age*6 + t));
      // lerp between flat map (wrap=0) and sphere (wrap=1)
      const px = (1-wrap)*d.fx[i] + wrap*(ux*(1+out*0.6));
      const py = (1-wrap)*d.fy[i] + wrap*(uy*(1+out*0.6));
      const pz = (1-wrap)*0 + wrap*(uz*(1+out*0.6));
      const x1 = px*cyr + pz*sy;
      const z1 = -px*sy + pz*cyr;
      const y2 = py*cxt - z1*sx;
      const z2 = py*sx + z1*cxt;
      const depth = Math.max(0, Math.min(1, (z2+1)/2));
      const size = (1 + 1.6*v) * (0.6 + 0.4*depth) * (Math.min(w,h)/360);
      const X = cx + x1*R;
      const Y = cy - y2*R;
      if (colorby === 'age' || colorby === 'pitch') {
        const hueVal = colorby === 'age' ? (172 + age*100)%360 : (28 + pitch*257)%360;
        // draw individually for color
        ctx.fillStyle = `hsla(${hueVal},85%,65%,${0.3+0.7*depth})`;
        ctx.beginPath(); ctx.arc(X,Y,size,0,Math.PI*2); ctx.fill();
      } else {
        const layer = layers[Math.min(3, Math.floor(depth*4))];
        layer.moveTo(X+size, Y);
        layer.arc(X, Y, size, 0, Math.PI*2);
      }
    }
    if (colorby === 'none') {
      const alphas = pulse ? [0.25,0.5,0.8,1] : [0.16,0.35,0.65,0.95];
      const lightness = pulse ? 55 : 70;
      layers.forEach((p,i) => {
        ctx.fillStyle = `hsla(${hue}, 80%, ${lightness}%, ${alphas[i]})`;
        ctx.fill(p);
      });
    }
    // glow core
    const grd = ctx.createRadialGradient(cx,cy,0,cx,cy,R*0.4);
    grd.addColorStop(0, `hsla(${hue},90%,75%,0.22)`);
    grd.addColorStop(1, `hsla(${hue},90%,75%,0)`);
    ctx.fillStyle = grd;
    ctx.fillRect(0,0,w,h);
  }
}
customElements.define('voice-orb', VoiceOrb);
