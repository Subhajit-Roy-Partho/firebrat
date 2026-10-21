(function () {
  var root = document.documentElement;
  var stored = null;
  try { stored = localStorage.getItem('firebrat-theme'); } catch (e) {}
  if (stored === 'light' || stored === 'dark') root.setAttribute('data-theme', stored);

  function currentTheme() {
    var attr = root.getAttribute('data-theme');
    if (attr) return attr;
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }

  function setTheme(t) {
    root.setAttribute('data-theme', t);
    try { localStorage.setItem('firebrat-theme', t); } catch (e) {}
    updateToggleIcon(t);
  }

  function updateToggleIcon(t) {
    var btn = document.getElementById('theme-toggle');
    if (!btn) return;
    btn.setAttribute('aria-label', t === 'dark' ? 'Switch to light theme' : 'Switch to dark theme');
  }

  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ---------- Hero wave canvas: layered narration waveforms + drifting particles ---------- */
  function initWave() {
    var canvas = document.getElementById('wave-canvas');
    if (!canvas || reduceMotion) return;
    var ctx = canvas.getContext('2d');
    if (!ctx) return;
    var w = 0, h = 0, dpr = 1, t = 0, running = true;
    var DPR_CAP = 1.5; // cheap on phones, still crisp

    var waves = [
      { amp: 0.16, len: 0.006, speed: 0.9, yOff: 0.42, hue: [255, 107, 74], alpha: 0.55, width: 2.2 },
      { amp: 0.11, len: 0.009, speed: -0.6, yOff: 0.52, hue: [255, 178, 56], alpha: 0.4, width: 1.8 },
      { amp: 0.08, len: 0.013, speed: 1.3, yOff: 0.6, hue: [124, 92, 255], alpha: 0.35, width: 1.5 },
      { amp: 0.05, len: 0.02, speed: -1.0, yOff: 0.35, hue: [34, 211, 238], alpha: 0.25, width: 1.2 }
    ];
    var dots = [];
    for (var i = 0; i < 46; i++) {
      dots.push({
        x: Math.random(), y: Math.random(),
        r: 0.8 + Math.random() * 2.0,
        vx: (Math.random() - 0.5) * 0.00022,
        vy: (Math.random() - 0.5) * 0.00018,
        a: 0.25 + Math.random() * 0.5,
        warm: Math.random() < 0.7
      });
    }

    function resize() {
      dpr = Math.min(window.devicePixelRatio || 1, DPR_CAP);
      var r = canvas.getBoundingClientRect();
      w = Math.max(1, Math.floor(r.width));
      h = Math.max(1, Math.floor(r.height));
      canvas.width = Math.floor(w * dpr);
      canvas.height = Math.floor(h * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }

    function waveY(cfg, x, time) {
      var base = h * cfg.yOff;
      return base
        + Math.sin(x * cfg.len * w * 0.01 + time * cfg.speed) * h * cfg.amp
        + Math.sin(x * cfg.len * w * 0.023 + time * cfg.speed * 1.7) * h * cfg.amp * 0.45;
    }

    function frame() {
      if (!running) return;
      t += 0.016;
      ctx.clearRect(0, 0, w, h);

      var k, x, y;
      for (k = 0; k < dots.length; k++) {
        var d = dots[k];
        d.x = (d.x + d.vx + 1) % 1;
        d.y = (d.y + d.vy + 1) % 1;
        ctx.beginPath();
        ctx.arc(d.x * w, d.y * h, d.r, 0, 6.2832);
        ctx.fillStyle = d.warm
          ? 'rgba(255,150,90,' + d.a.toFixed(3) + ')'
          : 'rgba(150,140,255,' + d.a.toFixed(3) + ')';
        ctx.fill();
      }

      for (k = 0; k < waves.length; k++) {
        var cfg = waves[k];
        ctx.beginPath();
        for (x = 0; x <= w; x += 4) {
          y = waveY(cfg, x, t);
          if (x === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        }
        ctx.strokeStyle = 'rgba(' + cfg.hue[0] + ',' + cfg.hue[1] + ',' + cfg.hue[2] + ',' + cfg.alpha + ')';
        ctx.lineWidth = cfg.width;
        ctx.stroke();

        // soft glow echo under the lead wave
        if (k === 0) {
          ctx.save();
          ctx.translate(0, 26);
          ctx.globalAlpha = 0.35;
          ctx.stroke();
          ctx.restore();
        }
      }
      requestAnimationFrame(frame);
    }

    resize();
    window.addEventListener('resize', resize);
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) { running = false; }
      else if (!running) { running = true; requestAnimationFrame(frame); }
    });
    requestAnimationFrame(frame);
  }

  /* ---------- Scroll reveals ---------- */
  function initReveals() {
    var els = document.querySelectorAll('.card, .pipe-step, .section-head, .quote-block, .cta, .mockup-wrap, .hero-stats');
    if (!els.length) return;
    if (reduceMotion || !('IntersectionObserver' in window)) {
      for (var i = 0; i < els.length; i++) els[i].classList.add('in');
      return;
    }
    for (var j = 0; j < els.length; j++) els[j].classList.add('reveal');
    var io = new IntersectionObserver(function (entries) {
      for (var k = 0; k < entries.length; k++) {
        if (entries[k].isIntersecting) {
          entries[k].target.classList.add('in');
          io.unobserve(entries[k].target);
        }
      }
    }, { threshold: 0.12, rootMargin: '0px 0px -6% 0px' });
    for (var m = 0; m < els.length; m++) io.observe(els[m]);
  }

  /* ---------- Animated counters ---------- */
  function initCounters() {
    var nums = document.querySelectorAll('.count[data-count]');
    if (!nums.length) return;
    function animate(el) {
      var target = parseInt(el.getAttribute('data-count'), 10);
      if (isNaN(target)) return;
      if (reduceMotion) { el.textContent = String(target); return; }
      var dur = 1400, start = null;
      function tick(now) {
        if (start === null) start = now;
        var p = Math.min(1, (now - start) / dur);
        var eased = 1 - Math.pow(1 - p, 3);
        el.textContent = String(Math.round(target * eased));
        if (p < 1) requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    }
    if (!('IntersectionObserver' in window)) {
      for (var i = 0; i < nums.length; i++) animate(nums[i]);
      return;
    }
    var io = new IntersectionObserver(function (entries) {
      for (var k = 0; k < entries.length; k++) {
        if (entries[k].isIntersecting) {
          animate(entries[k].target);
          io.unobserve(entries[k].target);
        }
      }
    }, { threshold: 0.4 });
    for (var j = 0; j < nums.length; j++) io.observe(nums[j]);
  }

  document.addEventListener('DOMContentLoaded', function () {
    updateToggleIcon(currentTheme());
    var toggle = document.getElementById('theme-toggle');
    if (toggle) {
      toggle.addEventListener('click', function () {
        setTheme(currentTheme() === 'dark' ? 'light' : 'dark');
      });
    }

    var navToggle = document.getElementById('nav-toggle');
    var navLinks = document.getElementById('nav-links');
    if (navToggle && navLinks) {
      navToggle.addEventListener('click', function () {
        var open = navLinks.classList.toggle('open');
        navToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
      });
    }

    initWave();
    initReveals();
    initCounters();
  });
})();
