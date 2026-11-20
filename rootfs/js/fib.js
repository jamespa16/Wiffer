// A computation with a known answer.
function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
console.log("fib(20) = " + fib(20));
var json = JSON.stringify({ a: [1, 2, { b: "x" }], c: null });
console.log("json = " + json + " " + (JSON.stringify(JSON.parse(json)) === json));
console.log([1, 2, 3].map(function (x) { return x * x; }), { n: 1, s: "two", nested: { deep: [1, 2] } });
console.log("%s is %d years and %i%% done %o", "answer", 42.5, 99.9, [1]);
