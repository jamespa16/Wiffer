// A timer sequence: order is by due time, then creation order.
function note(s) { console.log(s); }
setTimeout(function () { note("t200"); }, 200);
setTimeout(function () { note("t50"); }, 50);
setTimeout(function () { note("t0-first"); }, 0);
setTimeout(function () { note("t0-second"); }, 0);
queueMicrotask(function () { note("micro"); });
var n = 0;
var id = setInterval(function () {
  note("tick" + (++n));
  if (n === 3) { clearInterval(id); note("done"); }
}, 100);
var cancelled = setTimeout(function () { note("never"); }, 5);
clearTimeout(cancelled);
note("sync");
