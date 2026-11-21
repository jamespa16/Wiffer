// String building and globals (ROADMAP Phase 9J benchmark, written for
// Wiffer): `+=` in a loop, the way pages build HTML before one innerHTML
// assignment, and a loop over global variables (property access on the
// global object).

function concatLoop(n) {
  var s = "";
  for (var i = 0; i < n; i++) s += "x";
  return s.length;
}

function buildHTML(n) {
  var html = "<ul>";
  for (var i = 0; i < n; i++) html += "<li class=\"item\">Item " + i + "</li>";
  html += "</ul>";
  return html.length + html.charCodeAt(html.length - 2);
}

var g = { a: 1, b: 2 }, gs = 0, gi = 0;
function globalLoop(n) {
  for (gi = 0; gi < n; gi++) { g.a = gi; gs += g.a + g.b; }
  return gs;
}

var benchRuns = typeof benchScale === "number" ? benchScale : 1;
var benchT0 = Date.now();
var benchResult;
for (var benchI = 0; benchI < benchRuns; benchI++) {
  gs = 0;
  benchResult = concatLoop(100000) + "/" + buildHTML(20000) + "/" + globalLoop(300000);
}
if (typeof console !== "undefined") console.log("bench strings " + (Date.now() - benchT0) + " ms x" + benchRuns + " " + benchResult);
benchResult;
