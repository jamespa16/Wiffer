// Regex-heavy script (ROADMAP Phase 9J benchmark, written for Wiffer): a
// generated log-like text (800 lines) is tokenized, searched, rewritten with
// replacement functions and patterns, and split, the way templating and
// validation code uses regular expressions.

function makeText(lines) {
  var words = ["alpha", "beta", "gamma", "delta", "user@example.com", "2026-11-20", "GET /index.html", "404", "0x1F", "Wiffer"];
  var out = [];
  for (var i = 0; i < lines; i++) {
    out.push("[" + (i % 24) + ":" + (i % 60) + "] " + words[i % words.length] + " id=" + (i * 37 % 1000) +
             " " + words[(i * 3) % words.length] + " value=" + (i / 7).toFixed(3) + ";");
  }
  return out.join("\n");
}

function regexWork(text) {
  var n = 0;
  n += text.match(/\bid=\d+/g).length;
  n += (text.match(/[\w.]+@[\w.]+\.[a-z]{2,}/g) || []).length;
  n += (text.match(/\d{4}-\d{2}-\d{2}/g) || []).length;
  var re = /\[(\d+):(\d+)\]\s+(\w+)/g, r;
  while ((r = re.exec(text)) !== null) n += r[3].length;
  n += text.replace(/value=(\d+)\.(\d+)/g, function (all, a, b) { return "v=" + b + "." + a; }).length;
  n += text.replace(/(alpha|beta|gamma)/g, "<$1>").length;
  n += text.split(/[;\n]+/).length;
  var lines = text.split("\n");
  for (var i = 0; i < lines.length; i++) {
    if (/^\[\d+:\d+\] (GET|POST) \/\S+/.test(lines[i])) n++;
    if (/0x[0-9A-F]+/i.test(lines[i])) n++;
  }
  n += text.replace(/\s+/g, " ").trim().length;
  return n;
}

var benchRuns = typeof benchScale === "number" ? benchScale : 10;
var benchText = makeText(800);
var benchT0 = Date.now();
var benchResult = 0;
for (var benchI = 0; benchI < benchRuns; benchI++) benchResult = regexWork(benchText);
if (typeof console !== "undefined") console.log("bench regex " + (Date.now() - benchT0) + " ms x" + benchRuns + " " + benchResult);
benchResult;
