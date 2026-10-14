/*
  The app's backdrop (AppBackdrop.swift): a 3x3 mesh of quiet accent, violet, teal, indigo
  and rose tones mixed into the base colour, drifting slowly. Drawn into a small canvas
  that the browser scales up smoothly, so it costs almost nothing. Static under
  "Bewegung reduzieren", paused while off screen.
*/
(() => {
  'use strict';

  const canvases = document.querySelectorAll('canvas[data-backdrop]');
  if (!canvases.length) return;

  const dark = window.matchMedia('(prefers-color-scheme: dark)');
  const still = window.matchMedia('(prefers-reduced-motion: reduce)');
  const FPS = 12;

  const BASE = { light: 0xf6f6fb, dark: 0x0d0e16 };
  const ACCENT = { light: 0x5146e5, dark: 0x7b74ff };
  const TONES = { violet: 0x9d6bff, teal: 0x2bb3c0, indigo: 0x3d5bff, rose: 0xe58bd0 };
  // [tone, share in light mode, share in dark mode], in the order of AppBackdrop.palette
  const LAYOUT = [
    ['accent', 0.2, 0.34], ['violet', 0.12, 0.2], ['teal', 0.16, 0.22],
    ['indigo', 0.1, 0.18], ['accent', 0.06, 0.1], ['teal', 0.11, 0.16],
    ['rose', 0.12, 0.14], ['accent', 0.15, 0.26], ['violet', 0.17, 0.24],
  ];

  // ---- colour: sRGB <-> OKLab (mixing in a perceptual space, like SwiftUI's .perceptual)

  const linear = (c) => {
    const v = c / 255;
    return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  };

  const ENCODE = new Uint8ClampedArray(4096);
  for (let i = 0; i < 4096; i += 1) {
    const v = i / 4095;
    ENCODE[i] = Math.round(255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055));
  }
  const encode = (v) => ENCODE[v <= 0 ? 0 : v >= 1 ? 4095 : (v * 4095 + 0.5) | 0];

  function oklab(hex) {
    const r = linear((hex >> 16) & 255);
    const g = linear((hex >> 8) & 255);
    const b = linear(hex & 255);
    const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return [
      0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
    ];
  }

  function writeRgb(L, A, B, out, o) {
    const l = L + 0.3963377774 * A + 0.2158037573 * B;
    const m = L - 0.1055613458 * A - 0.0638541728 * B;
    const s = L - 0.0894841775 * A - 1.291485548 * B;
    const l3 = l * l * l;
    const m3 = m * m * m;
    const s3 = s * s * s;
    out[o] = encode(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3);
    out[o + 1] = encode(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3);
    out[o + 2] = encode(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.707614701 * s3);
    out[o + 3] = 255;
  }

  // ---- geometry: AppBackdrop.points(time:)

  function points(t) {
    const wave = (period, phase = 0) => Math.sin((t / period + phase) * 2 * Math.PI);
    const a = 0.07;
    return [
      [0, 0], [0.5 + a * wave(29), 0], [1, 0],
      [0, 0.5 + a * wave(37, 0.3)], [0.5 + a * wave(31, 0.6), 0.5 + a * wave(41, 0.1)], [1, 0.5 + a * wave(33, 0.8)],
      [0, 1], [0.5 + a * wave(43, 0.45), 1], [1, 1],
    ];
  }

  // Quadratic Lagrange weights through 0, 0.5 and 1: the surface passes through every
  // control colour, like MeshGradient does.
  function weights(t, out) {
    out[0] = 2 * (t - 0.5) * (t - 1);
    out[1] = -4 * t * (t - 1);
    out[2] = 2 * t * (t - 0.5);
  }

  class Backdrop {
    constructor(canvas) {
      this.canvas = canvas;
      this.context = canvas.getContext('2d', { alpha: false });
      this.intensity = Number.parseFloat(canvas.dataset.intensity) || 1;
      this.phase = canvas.closest('.window') ? 7 : 0;
      this.visible = true;
      this.wx = new Float32Array(3);
      this.wy = new Float32Array(3);
      this.colours();
      this.resize();
    }

    colours() {
      const isDark = dark.matches;
      const base = oklab(isDark ? BASE.dark : BASE.light);
      this.palette = LAYOUT.map(([tone, lightShare, darkShare]) => {
        const hex = tone === 'accent' ? (isDark ? ACCENT.dark : ACCENT.light) : TONES[tone];
        const c = oklab(hex);
        const k = Math.min(1, (isDark ? darkShare : lightShare) * this.intensity);
        return [base[0] + (c[0] - base[0]) * k, base[1] + (c[1] - base[1]) * k, base[2] + (c[2] - base[2]) * k];
      });
    }

    resize() {
      const rect = this.canvas.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      const width = Math.max(24, Math.min(112, Math.round(rect.width / 14)));
      const height = Math.max(16, Math.min(112, Math.round((width * rect.height) / rect.width)));
      if (width !== this.canvas.width || height !== this.canvas.height || !this.image) {
        this.canvas.width = width;
        this.canvas.height = height;
        this.image = this.context.createImageData(width, height);
      }
    }

    draw(time) {
      if (!this.image) return;
      const { width, height, data } = this.image;
      const P = points(time + this.phase);
      const D = P.map(([x, y], i) => [x - (i % 3) * 0.5, y - Math.floor(i / 3) * 0.5]);
      const C = this.palette;
      const wx = this.wx;
      const wy = this.wy;

      // Displacement of the mesh at (x, y): the same weights over the control offsets.
      const shift = (x, y) => {
        weights(x, wx);
        weights(y, wy);
        let dx = 0;
        let dy = 0;
        for (let r = 0; r < 3; r += 1) {
          for (let c = 0; c < 3; c += 1) {
            const w = wy[r] * wx[c];
            const d = D[r * 3 + c];
            dx += w * d[0];
            dy += w * d[1];
          }
        }
        return [dx, dy];
      };

      let o = 0;
      for (let j = 0; j < height; j += 1) {
        const y = height === 1 ? 0 : j / (height - 1);
        for (let i = 0; i < width; i += 1) {
          const x = width === 1 ? 0 : i / (width - 1);
          // Where on the undistorted grid this pixel comes from (two fixed-point steps).
          let [dx, dy] = shift(x, y);
          [dx, dy] = shift(Math.min(1, Math.max(0, x - dx)), Math.min(1, Math.max(0, y - dy)));
          const u = Math.min(1, Math.max(0, x - dx));
          const v = Math.min(1, Math.max(0, y - dy));
          weights(u, wx);
          weights(v, wy);
          let L = 0;
          let A = 0;
          let B = 0;
          for (let r = 0; r < 3; r += 1) {
            for (let c = 0; c < 3; c += 1) {
              const w = wy[r] * wx[c];
              const col = C[r * 3 + c];
              L += w * col[0];
              A += w * col[1];
              B += w * col[2];
            }
          }
          writeRgb(L, A, B, data, o);
          o += 4;
        }
      }
      this.context.putImageData(this.image, 0, 0);
    }
  }

  const items = [...canvases].map((canvas) => new Backdrop(canvas));
  const start = performance.now();
  let frame = 0;
  let last = 0;

  const drawAll = (time) => {
    for (const item of items) if (item.visible) item.draw(time);
  };

  function loop(now) {
    frame = 0;
    if (still.matches || document.hidden) return;
    if (now - last >= 1000 / FPS) {
      last = now;
      drawAll((now - start) / 1000);
    }
    if (items.some((item) => item.visible)) frame = requestAnimationFrame(loop);
  }

  function run() {
    if (still.matches) {
      cancelAnimationFrame(frame);
      frame = 0;
      for (const item of items) item.draw(0);
      return;
    }
    drawAll((performance.now() - start) / 1000);
    if (!frame) frame = requestAnimationFrame(loop);
  }

  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const item = items.find((candidate) => candidate.canvas === entry.target);
          if (item) item.visible = entry.isIntersecting;
        }
        run();
      },
      { rootMargin: '120px' },
    );
    items.forEach((item) => observer.observe(item.canvas));
  }

  if ('ResizeObserver' in window) {
    const resizer = new ResizeObserver(() => {
      items.forEach((item) => item.resize());
      for (const item of items) item.draw(still.matches ? 0 : (performance.now() - start) / 1000);
    });
    items.forEach((item) => resizer.observe(item.canvas));
  }

  const restyle = () => {
    items.forEach((item) => item.colours());
    for (const item of items) item.draw(still.matches ? 0 : (performance.now() - start) / 1000);
  };
  dark.addEventListener('change', restyle);
  still.addEventListener('change', run);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) run();
  });

  run();
})();
