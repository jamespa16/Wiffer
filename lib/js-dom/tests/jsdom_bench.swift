// DOM benchmark (ROADMAP Phase 9J): build 10 000 nodes through the DOM API
// (createElement, setAttribute, textContent, appendChild), query them, then
// restyle + lay out + paint the result; and the same list through one
// innerHTML assignment. By default it runs as a correctness check; with
// WIFFER_JS_BENCH=1 the times are printed:
//
//     WIFFER_JS_BENCH=1 WIFFER_JSDOM_ONLY=bench ./run.sh --hosttest js-dom
//
// The script is also rootfs-free: tests/web/js/dombench.html runs the same
// code in the browser (title shows the times under QEMU).

let jsdomBenchScript = """
    var t0 = Date.now();
    var ul = document.createElement('ul');
    for (var i = 0; i < 5000; i++) {
      var li = document.createElement('li');
      li.setAttribute('class', i % 2 ? 'odd' : 'even');
      li.textContent = 'item ' + i;
      ul.appendChild(li);
    }
    document.body.appendChild(ul);
    var t1 = Date.now();
    var n = document.querySelectorAll('li.odd').length + document.getElementsByTagName('li').length;
    var html = '';
    for (var j = 0; j < 5000; j++) html += '<p class="p' + (j % 3) + '">para ' + j + '</p>';
    var div = document.createElement('div');
    div.innerHTML = html;
    document.body.appendChild(div);
    var t2 = Date.now();
    console.log(n + ' ' + div.childNodes.length + ' ' + document.body.getElementsByTagName('*').length);
    """

func jsdomBenchTests(_ t: Tests) {
    t.section("bench")
    let p = JSDOMLayoutPage(t, "<!DOCTYPE html><style>li.odd { color: red } .p1 { margin: 2px }</style><body></body>", width: 800, height: 600)
    let start = hostMillis()
    p.page.runScript(jsdomBenchScript, name: "dombench.js")
    p.settle()
    let script = hostMillis() - start
    let l0 = hostMillis()
    p.engine.update()
    var px = [UInt32](repeating: 0, count: 800 * 600)
    px.withUnsafeMutableBufferPointer { b in p.engine.paint(into: b.baseAddress!, stride: 800, width: 800, height: 600, scrollX: 0, scrollY: 0) }
    let layout = hostMillis() - l0
    t.equal(p.box.lines.last ?? "", "7500 5000 10002", "dom bench: 10 000 nodes built and queried")
    if jsdomEnv("WIFFER_JS_BENCH") != nil {
        print("js-dom bench: build 10 000 nodes (5000 by createElement, 5000 by innerHTML) + query \(script) ms; update + paint \(layout) ms")
    }
    p.page.tearDown()

    // WIFFER_JSDOM_NODES=n: the hostile "million nodes" script for n nodes
    // (memory and time of building, then laying out and painting them).
    if let ns = jsdomEnv("WIFFER_JSDOM_NODES"), let n = Int(ns) {
        let q = JSDOMLayoutPage(t, "<!DOCTYPE html><body></body>", width: 800, height: 600, budgetMs: 60_000)
        let s0 = hostMillis()
        q.page.runScript("var b = document.body; for (var i = 0; i < \(n); i++) b.appendChild(document.createElement('div')).textContent = i;", name: "nodes.js")
        let s1 = hostMillis()
        print("sizes: style \(MemoryLayout<CSSComputedStyle>.size)")
        print("js-dom nodes: \(n) built in \(s1 - s0) ms, peak \(host_peak_rss_mb()) MiB")
        q.engine.update()
        var qx = [UInt32](repeating: 0, count: 800 * 600)
        qx.withUnsafeMutableBufferPointer { b in q.engine.paint(into: b.baseAddress!, stride: 800, width: 800, height: 600, scrollX: 0, scrollY: 0) }
        print("js-dom nodes: layout + paint \(hostMillis() - s1) ms, peak \(host_peak_rss_mb()) MiB")
    }
}
