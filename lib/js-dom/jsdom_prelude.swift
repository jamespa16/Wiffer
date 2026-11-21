// Small platform APIs written in JavaScript (ROADMAP Phase 9J), evaluated
// once per page after the bindings are installed. They are the ones real
// sites call unguarded at startup, where a missing global throws and takes
// the rest of a bundle with it (Wikipedia's Vector skin dies on
// `new IntersectionObserver`, its analytics on PerformanceObserver, and
// VisualEditor's init on `HTMLDocument`):
//
//   * IntersectionObserver: observe/unobserve/disconnect/takeRecords;
//     intersections of getBoundingClientRect() with the viewport (or the
//     root element's rect, grown by rootMargin in px), thresholds, entries
//     queued and delivered from a task after observe(), scroll and resize.
//   * ResizeObserver: the border box size from getBoundingClientRect(),
//     delivered after observe() and when it changes on resize or scroll.
//   * PerformanceObserver: accepted and never fires (no entry types).
//   * HTMLDocument: an alias of Document.
//   * navigator.serviceWorker: a container with no registrations whose
//     register() rejects (sites call it unguarded).
//   * navigator.clipboard: writeText/readText on a page-local string.
//
// Nothing here can hang: work happens only in response to the page's own
// calls and events, each check is linear in the observed targets.

let jsdomPreludeSource = """
(function (g) {
  'use strict';
  function def(name, v) {
    if (!Object.prototype.hasOwnProperty.call(g, name)) Object.defineProperty(g, name, { value: v, writable: true, configurable: true });
  }
  if (typeof Document === 'function') def('HTMLDocument', Document);

  var observers = [];
  var pending = false;
  function schedule() {
    if (pending) return;
    pending = true;
    setTimeout(function () {
      pending = false;
      var list = observers.slice();
      for (var i = 0; i < list.length; i++) list[i]._check();
    }, 0);
  }
  g.addEventListener('scroll', schedule, true);
  g.addEventListener('resize', schedule);

  function px(s) { var n = parseFloat(s); return isNaN(n) ? 0 : n; }
  function margins(s) {
    var p = String(s || '0px').trim().split(/\\s+/).map(px);
    if (p.length === 1) return [p[0], p[0], p[0], p[0]];
    if (p.length === 2) return [p[0], p[1], p[0], p[1]];
    if (p.length === 3) return [p[0], p[1], p[2], p[1]];
    return [p[0], p[1], p[2], p[3]];
  }
  function rect(t, r, b, l) {
    return { top: t, right: r, bottom: b, left: l, x: l, y: t, width: Math.max(0, r - l), height: Math.max(0, b - t) };
  }

  function IntersectionObserver(callback, options) {
    if (!(this instanceof IntersectionObserver)) throw new TypeError("Failed to construct 'IntersectionObserver': Please use the 'new' operator");
    if (typeof callback !== 'function') throw new TypeError("Failed to construct 'IntersectionObserver': parameter 1 is not of type 'Function'.");
    options = options || {};
    var th = options.threshold === undefined ? [0] : [].concat(options.threshold);
    for (var i = 0; i < th.length; i++) {
      th[i] = +th[i];
      if (!(th[i] >= 0 && th[i] <= 1)) throw new RangeError('Threshold values must be numbers between 0 and 1');
    }
    th.sort(function (a, b) { return a - b; });
    Object.defineProperty(this, '_s', { value: { cb: callback, targets: [], prev: [], records: [], margin: margins(options.rootMargin) } });
    this.root = options.root || null;
    this.rootMargin = String(options.rootMargin || '0px');
    this.thresholds = th;
  }
  IntersectionObserver.prototype.observe = function (el) {
    var s = this._s;
    if (s.targets.indexOf(el) >= 0) return;
    s.targets.push(el);
    s.prev.push(-1);
    if (observers.indexOf(this) < 0) observers.push(this);
    schedule();
  };
  IntersectionObserver.prototype.unobserve = function (el) {
    var s = this._s, i = s.targets.indexOf(el);
    if (i >= 0) { s.targets.splice(i, 1); s.prev.splice(i, 1); }
  };
  IntersectionObserver.prototype.disconnect = function () {
    this._s.targets = []; this._s.prev = [];
    var i = observers.indexOf(this);
    if (i >= 0) observers.splice(i, 1);
  };
  IntersectionObserver.prototype.takeRecords = function () {
    var r = this._s.records; this._s.records = []; return r;
  };
  IntersectionObserver.prototype._check = function () {
    var s = this._s, m = s.margin, root;
    if (this.root && this.root.getBoundingClientRect) {
      var rr = this.root.getBoundingClientRect();
      root = rect(rr.top - m[0], rr.right + m[1], rr.bottom + m[2], rr.left - m[3]);
    } else {
      root = rect(-m[0], g.innerWidth + m[1], g.innerHeight + m[2], -m[3]);
    }
    var now = g.performance ? g.performance.now() : 0;
    for (var i = 0; i < s.targets.length; i++) {
      var el = s.targets[i];
      var b = el.getBoundingClientRect();
      var connected = el.isConnected;
      var t = Math.max(b.top, root.top), l = Math.max(b.left, root.left);
      var bo = Math.min(b.bottom, root.bottom), ri = Math.min(b.right, root.right);
      var hit = connected && bo >= t && ri >= l;
      var inter = hit ? rect(t, ri, bo, l) : rect(0, 0, 0, 0);
      var area = b.width * b.height;
      var ratio = hit ? (area > 0 ? (inter.width * inter.height) / area : 1) : 0;
      var idx = -1;
      for (var k = 0; k < this.thresholds.length; k++) if (ratio >= this.thresholds[k]) idx = k;
      var state = hit ? idx + 1 : 0;
      if (state === s.prev[i]) continue;
      s.prev[i] = state;
      s.records.push({ time: now, target: el, rootBounds: root, boundingClientRect: b, intersectionRect: inter,
                       isIntersecting: hit, intersectionRatio: ratio, isVisible: false });
    }
    if (s.records.length) {
      var recs = this.takeRecords();
      s.cb.call(this, recs, this);
    }
  };

  function ResizeObserver(callback) {
    if (!(this instanceof ResizeObserver)) throw new TypeError("Failed to construct 'ResizeObserver': Please use the 'new' operator");
    if (typeof callback !== 'function') throw new TypeError("Failed to construct 'ResizeObserver': parameter 1 is not of type 'Function'.");
    Object.defineProperty(this, '_s', { value: { cb: callback, targets: [], sizes: [] } });
  }
  ResizeObserver.prototype.observe = function (el) {
    var s = this._s;
    if (s.targets.indexOf(el) >= 0) return;
    s.targets.push(el);
    s.sizes.push(null);
    if (observers.indexOf(this) < 0) observers.push(this);
    schedule();
  };
  ResizeObserver.prototype.unobserve = function (el) {
    var s = this._s, i = s.targets.indexOf(el);
    if (i >= 0) { s.targets.splice(i, 1); s.sizes.splice(i, 1); }
  };
  ResizeObserver.prototype.disconnect = function () {
    this._s.targets = []; this._s.sizes = [];
    var i = observers.indexOf(this);
    if (i >= 0) observers.splice(i, 1);
  };
  ResizeObserver.prototype._check = function () {
    var s = this._s, entries = [];
    for (var i = 0; i < s.targets.length; i++) {
      var el = s.targets[i], b = el.getBoundingClientRect();
      var key = b.width + 'x' + b.height;
      if (key === s.sizes[i]) continue;
      s.sizes[i] = key;
      var size = [{ inlineSize: b.width, blockSize: b.height }];
      entries.push({ target: el, contentRect: rect(0, b.width, b.height, 0), borderBoxSize: size, contentBoxSize: size,
                     devicePixelContentBoxSize: size });
    }
    if (entries.length) s.cb.call(this, entries, this);
  };

  function PerformanceObserver(callback) {
    if (!(this instanceof PerformanceObserver)) throw new TypeError("Failed to construct 'PerformanceObserver': Please use the 'new' operator");
    if (typeof callback !== 'function') throw new TypeError("Failed to construct 'PerformanceObserver': parameter 1 is not of type 'Function'.");
  }
  PerformanceObserver.prototype.observe = function () {};
  PerformanceObserver.prototype.disconnect = function () {};
  PerformanceObserver.prototype.takeRecords = function () { return []; };
  Object.defineProperty(PerformanceObserver, 'supportedEntryTypes', { value: Object.freeze([]), configurable: true });

  // No service workers: a container whose register() rejects and which has
  // no registrations (preactjs.com calls getRegistrations() unguarded).
  if (g.navigator && !g.navigator.serviceWorker) {
    var sw = {
      controller: null,
      ready: new Promise(function () {}),
      register: function () { return Promise.reject(new DOMException('Service workers are not supported', 'NotSupportedError')); },
      getRegistration: function () { return Promise.resolve(undefined); },
      getRegistrations: function () { return Promise.resolve([]); },
      startMessages: function () {},
      addEventListener: function () {},
      removeEventListener: function () {},
      oncontrollerchange: null, onmessage: null, onmessageerror: null
    };
    Object.defineProperty(g.navigator, 'serviceWorker', { value: sw, configurable: true, enumerable: true });
  }

  // A page-local clipboard ('clipboard' in navigator was true but the value
  // undefined; GitHub's copy buttons call navigator.clipboard.read).
  if (g.navigator && !g.navigator.clipboard) {
    var clip = '';
    var cb = {
      writeText: function (t) { clip = String(t); return Promise.resolve(); },
      readText: function () { return Promise.resolve(clip); },
      write: function () { return Promise.resolve(); },
      read: function () { return Promise.resolve([]); },
      addEventListener: function () {},
      removeEventListener: function () {}
    };
    Object.defineProperty(g.navigator, 'clipboard', { value: cb, configurable: true, enumerable: true });
  }

  def('IntersectionObserver', IntersectionObserver);
  def('ResizeObserver', ResizeObserver);
  def('PerformanceObserver', PerformanceObserver);
})(globalThis);
"""
