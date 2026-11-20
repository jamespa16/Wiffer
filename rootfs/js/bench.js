// Timings for ROADMAP's Phase 9F numbers (performance.now() is in 10 ms steps).
function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
function time(label, f) {
  var t0 = performance.now();
  var r = f();
  console.log(label + ": " + (performance.now() - t0) + " ms (" + r + ")");
}
time("fib(25)", function () { return fib(25); });
time("json round trip x200", function () {
  var o = { a: [1, 2, 3, { b: "text", c: [true, false, null] }], d: { e: 1.5, f: "x".repeat(50) } };
  var n = 0;
  for (var i = 0; i < 200; i++) n += JSON.parse(JSON.stringify(o)).a.length;
  return n;
});
time("array push+sort 20000", function () {
  var a = [];
  for (var i = 0; i < 20000; i++) a.push((i * 7919) % 10007);
  a.sort(function (x, y) { return x - y; });
  return a[100];
});
time("string concat+regexp 5000", function () {
  var s = "";
  for (var i = 0; i < 5000; i++) s += "item" + i + ",";
  return s.match(/item\d+7,/g).length;
});
time("object alloc 100000", function () {
  var keep = [];
  for (var i = 0; i < 100000; i++) keep.push({ n: i, a: [1, 2] });
  return keep.length;
});
