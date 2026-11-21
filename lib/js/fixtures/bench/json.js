// JSON round trip (ROADMAP Phase 9J benchmark, written for Wiffer): a
// 500-record document of nested objects, arrays, strings with escapes and
// numbers is stringified (plain and indented) and parsed back, then checked.

function makeDoc(n) {
  var items = [];
  for (var i = 0; i < n; i++) {
    items.push({
      id: i, name: "item \"" + i + "\"\né", price: i * 1.25 + 0.1, tags: ["a" + (i % 7), "b", "c" + (i % 3)],
      ok: i % 2 == 0, none: null, nested: { depth: 1, list: [i, i + 1, { x: i / 3 }] }
    });
  }
  return { version: 3, title: "Wiffer JSON bench", items: items };
}

function jsonRound(doc, rounds) {
  var total = 0;
  for (var r = 0; r < rounds; r++) {
    var text = JSON.stringify(doc);
    var back = JSON.parse(text);
    if (back.items.length != doc.items.length || back.items[7].name != doc.items[7].name) throw new Error("json mismatch");
    total += text.length;
    if (r % 5 == 0) total += JSON.stringify(back, null, 2).length;
  }
  return total;
}

var benchRuns = typeof benchScale === "number" ? benchScale : 20;
var benchT0 = Date.now();
var benchResult = jsonRound(makeDoc(500), benchRuns);
if (typeof console !== "undefined") console.log("bench json " + (Date.now() - benchT0) + " ms x" + benchRuns + " " + benchResult);
benchResult;
