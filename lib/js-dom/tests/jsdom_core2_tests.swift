// More lib/js-dom behavior: events, handlers, shadow retargeting,
// MutationObserver, style, forms, history, matchMedia, GC and the
// Swift-side entry points the browser uses.

func jsdomCore2Tests(_ t: Tests) {
    t.section("lookup and collection invalidation")
    let lookup = JSDOMTestPage("<body><div id=first class=x><span id=nested></span></div><p id=first></p></body>")
    t.equal(lookup.run("""
    var first = document.getElementById('first');
    console.log(first.tagName, document.getElementById('nested').tagName, document.getElementById('missing'));
    first.remove(); console.log(document.getElementById('first').tagName);
    var frag = document.createDocumentFragment();
    var a = document.createElement('i'); a.id = 'a'; frag.appendChild(a);
    console.log(frag.getElementById('a') === a, document.getElementById('a'));
    a.id = 'b'; console.log(frag.getElementById('a'), frag.getElementById('b') === a);
    """), "DIV SPAN null\nP\ntrue null\nnull true", "ID lookup preserves tree order, removal and detached fragment updates")
    let cb = lookup.page.bindings
    let tags = JSDOMHTMLCollection(cb.document, .tagName("p"))
    let classes = JSDOMHTMLCollection(cb.document, .className(["x"]))
    t.equal(cb.collectionItems(tags).count, 1, "tag collection initial membership")
    t.equal(cb.collectionItems(classes).count, 0, "class collection initial membership")
    let tagVersion = tags.cacheVersion, classVersion = classes.cacheVersion
    _ = lookup.run("document.body.firstChild.setAttribute('style', 'color:red'); document.body.firstChild.appendChild(document.createTextNode('a')); ")
    // Adding text is still structural; changing existing text must not be.
    _ = cb.collectionItems(tags); _ = cb.collectionItems(classes)
    let afterTextInsert = tags.cacheVersion, classAfterTextInsert = classes.cacheVersion
    _ = lookup.run("document.body.firstChild.firstChild.data = 'b'; document.body.firstChild.id = 'changed';")
    _ = cb.collectionItems(tags); _ = cb.collectionItems(classes)
    t.equal(tags.cacheVersion, afterTextInsert, "text and ID changes preserve tag cache")
    t.equal(classes.cacheVersion, classAfterTextInsert, "text and ID changes preserve class cache")
    _ = lookup.run("document.body.firstChild.className = 'x';")
    t.equal(cb.collectionItems(classes).count, 1, "class changes refresh class membership")
    _ = cb.collectionItems(tags)
    t.equal(tags.cacheVersion, afterTextInsert, "class changes preserve tag cache")
    _ = lookup.run("document.body.appendChild(document.createElement('p'));")
    t.equal(cb.collectionItems(tags).count, 2, "structural changes refresh tag membership")
    t.check(tags.cacheVersion != tagVersion && classes.cacheVersion != classVersion, "relevant mutations advance cache versions")

    t.section("events")
    let p = JSDOMTestPage("""
    <!DOCTYPE html><body><div id=outer><p id=inner><b id=leaf>x</b></p></div>
    <button id=btn onclick="console.log('attr', event.type, this.id); return false">B</button>
    <form id=f action="/go"><input id=cb type=checkbox><input id=t name=q value=v><button id=sub>S</button></form>
    <a id=link href="next.html">L</a></body>
    """)
    t.equal(p.run("""
    var log = [];
    ['outer', 'inner', 'leaf'].forEach(function (id) {
      var el = document.getElementById(id);
      el.addEventListener('ev', function (e) { log.push('cap:' + id + ':' + e.eventPhase); }, true);
      el.addEventListener('ev', function (e) { log.push('bub:' + id + ':' + e.eventPhase); });
    });
    document.getElementById('leaf').dispatchEvent(new Event('ev', {bubbles: true}));
    console.log(log.join(' '));
    """), "cap:outer:1 cap:inner:1 cap:leaf:2 bub:leaf:2 bub:inner:3 bub:outer:3", "capture/target/bubble order")
    t.equal(p.run("""
    var n = 0, el = document.getElementById('inner');
    function h() { n++; }
    el.addEventListener('x', h, {once: true});
    el.dispatchEvent(new Event('x')); el.dispatchEvent(new Event('x'));
    el.addEventListener('y', function (e) { e.stopImmediatePropagation(); n += 10; });
    el.addEventListener('y', function () { n += 100; });
    el.dispatchEvent(new Event('y'));
    el.addEventListener('z', function (e) { e.preventDefault(); console.log('passive canceled', e.defaultPrevented); }, {passive: true});
    console.log(n, el.dispatchEvent(new Event('z', {cancelable: true})));
    """), "passive canceled false\n11 true", "once, stopImmediatePropagation, passive")
    t.equal(p.run("var r = document.getElementById('btn').dispatchEvent(new MouseEvent('click', {cancelable: true})); console.log(r, typeof document.getElementById('btn').onclick)"),
            "attr click btn\nfalse function", "onclick content attribute, return false cancels")
    t.equal(p.run("var b = document.getElementById('btn'); b.onclick = function () { console.log('idl') }; b.click(); b.setAttribute('onclick', 'console.log(\"again\")'); b.click(); b.onclick = null; b.click(); console.log('end')"),
            "idl\nagain\nend", "handler IDL attribute and content attribute changes")
    t.equal(p.run("var ac = new AbortController(); var c = 0; document.body.addEventListener('q', function () { c++ }, {signal: ac.signal}); document.body.dispatchEvent(new Event('q')); ac.abort(); document.body.dispatchEvent(new Event('q')); console.log(c, ac.signal.aborted, ac.signal.reason.name)"),
            "1 true AbortError", "AbortSignal removes listeners")
    t.equal(p.run("var cb = document.getElementById('cb'); cb.addEventListener('change', function () { console.log('change', cb.checked) }); cb.click(); cb.addEventListener('click', function (e) { e.preventDefault() }); cb.click(); console.log(cb.checked)"),
            "change true\ntrue", "checkbox activation and canceled activation")
    t.equal(p.run("""
    var host = document.createElement('div'); document.body.appendChild(host);
    var root = host.attachShadow({mode: 'open'}); root.innerHTML = '<span id=s>in shadow</span>';
    var s = root.getElementById('s'), seen = [];
    document.body.addEventListener('click', function (e) { seen.push('body:' + e.target.tagName + ':' + e.composedPath().length); });
    root.addEventListener('click', function (e) { seen.push('root:' + e.target.id); });
    s.dispatchEvent(new MouseEvent('click', {bubbles: true, composed: true}));
    s.dispatchEvent(new MouseEvent('click', {bubbles: true}));
    console.log(seen.join(' '));
    """), "root:s body:DIV:7 root:s", "shadow retargeting and composed")

    t.section("mutation observer")
    t.equal(p.run("""
    var target = document.getElementById('outer');
    var mo = new MutationObserver(function (records, obs) {
      obs.disconnect();
      console.log(records.length, records.map(function (r) { return r.type + ':' + (r.attributeName || r.addedNodes.length) + ':' + r.oldValue; }).join(','), obs === mo);
    });
    mo.observe(target, {attributes: true, childList: true, subtree: true, attributeOldValue: true});
    target.setAttribute('data-a', '1'); target.setAttribute('data-a', '2');
    target.appendChild(document.createElement('i'));
    console.log('sync');
    """), "sync\n3 attributes:data-a:null,attributes:data-a:1,childList:1:null true", "records delivered as a microtask")

    t.section("style")
    t.equal(p.run("var d = document.getElementById('outer'); d.style.color = 'red'; d.style.setProperty('margin-left', '3px', 'important'); d.style.backgroundColor = 'blue'; console.log(d.getAttribute('style')); console.log(d.style.length, d.style.marginLeft, d.style.getPropertyPriority('margin-left'), d.style[0]); d.style.color = ''; d.style.width = 'bogus'; console.log(d.style.cssText)"),
            "color: red; margin-left: 3px !important; background-color: blue;\n3 3px important color\nmargin-left: 3px !important; background-color: blue;",
            "element.style over the style attribute")
    t.equal(p.run("var d = document.getElementById('outer'); d.style.cssText = 'display:none; transform: rotate(3deg)'; console.log(d.style.display, d.style.transform, d.style.cssText)"),
            "none rotate(3deg) display: none; transform: rotate(3deg);", "cssText and unknown-to-lib/css properties")

    t.section("forms and navigation hooks")
    var submitted: [String] = []
    var navigations: [String] = []
    var pushes: [String] = []
    let f = JSDOMTestPage("<form id=f action='/go'><input name=q id=q value=v><button id=sub>S</button></form><a id=link href='next.html'>L</a>") { h in
        h.submitForm = { form, sub in submitted.append((form.attribute("id") ?? "") + "/" + (sub?.attribute("id") ?? "-")) }
        h.followHyperlink = { _, url, _ in navigations.append(url) }
        h.navigate = { url, replace in navigations.append((replace ? "replace " : "") + url) }
        h.historyPush = { id, url, replace in pushes.append(String(id) + " " + url + (replace ? " r" : "")) }
    }
    _ = f.run("document.getElementById('sub').click()")
    _ = f.run("document.getElementById('f').addEventListener('submit', function (e) { e.preventDefault(); console.log('prevented') }); document.getElementById('sub').click()")
    t.equal(submitted.joined(separator: ","), "f/sub", "submit button submits; preventDefault in submit stops it")
    _ = f.run("document.getElementById('link').click(); location.href = 'other.html'; location.replace('/abs')")
    t.equal(navigations.joined(separator: ","), "https://example.test/dir/next.html,https://example.test/dir/other.html,replace https://example.test/abs",
            "link activation and location assignment")
    t.equal(f.run("history.pushState({a: 1}, '', '?x=1'); console.log(location.href, history.state.a); location.hash = 'frag'; console.log(location.hash)"),
            "https://example.test/dir/page.html?x=1 1\n#frag", "pushState and fragment navigation")
    t.equal(pushes.joined(separator: ","), "1 https://example.test/dir/page.html?x=1,2 https://example.test/dir/page.html?x=1#frag", "history hooks")
    _ = f.run("window.addEventListener('popstate', function (e) { console.log('pop', JSON.stringify(e.state), location.search) })")
    f.box.lines = []
    f.page.popState(id: 1, url: "https://example.test/dir/page.html?x=1")
    t.equal(f.box.lines.joined(separator: ","), "pop {\"a\":1} ?x=1", "popState fires popstate with the state")
    t.equal(f.run("try { history.pushState(null, '', 'https://other.test/') } catch (e) { console.log(e.name) }"), "SecurityError", "cross-origin pushState")

    t.section("window")
    var w = 1024
    let m = JSDOMTestPage("<body>") { h in h.viewport = { (w, 768) } }
    t.equal(m.run("var mq = matchMedia('(max-width: 600px)'); console.log(mq.matches, innerWidth); mq.addEventListener('change', function (e) { console.log('change', e.matches) })"),
            "false 1024", "matchMedia")
    w = 500
    m.box.lines = []
    m.page.viewportChanged()
    t.equal(m.box.lines.joined(separator: ","), "change true", "matchMedia change on viewport change")
    t.equal(m.run("var id = requestAnimationFrame(function (t) { console.log('raf', typeof t) }); requestAnimationFrame(function () { console.log('raf2') }); console.log(typeof id)"),
            "number", "requestAnimationFrame queues")
    m.box.lines = []
    m.page.runAnimationFrames(now: 16)
    t.equal(m.box.lines.joined(separator: ","), "raf number,raf2", "runAnimationFrames runs them")
    t.equal(m.run("console.log(btoa('hello'), atob('aGVsbG8='), window === self, globalThis === window, typeof navigator.userAgent, navigator.language)"),
            "aGVsbG8= hello true true string en-US", "window basics")
    t.equal(m.run("localStorage.setItem('k', 'v'); localStorage.x = 'y'; console.log(localStorage.getItem('k'), localStorage.length, localStorage.x, Object.keys(localStorage).join())"),
            "v 2 y k,x", "localStorage")
    t.equal(m.run("var c = structuredClone({a: [1, {b: 2}], d: new Date(0)}); console.log(c.a[1].b, c.d.getTime())"), "2 0", "structuredClone")

    t.section("collections and attributes")
    let c = JSDOMTestPage("<ul id=u><li class=a>1</li><li>2</li></ul><div id=d data-foo-bar=baz title=t></div>")
    t.equal(c.run("var ch = document.getElementById('u').children; var n = ch.length; document.getElementById('u').appendChild(document.createElement('li')); console.log(n, ch.length, ch[0].textContent, ch.item(5), Array.from(ch).length)"),
            "2 3 1 null 3", "live HTMLCollection")
    t.equal(c.run("var cn = document.getElementById('u').childNodes; console.log(cn.length, cn === document.getElementById('u').childNodes); var a = []; cn.forEach(function (x) { a.push(x.nodeName) }); console.log(a.join())"),
            "3 true\nLI,LI,LI", "childNodes is live and [SameObject]")
    t.equal(c.run("var d = document.getElementById('d'); console.log(d.dataset.fooBar); d.dataset.newKey = 'v'; console.log(d.getAttribute('data-new-key'), Object.keys(d.dataset).join()); delete d.dataset.fooBar; console.log(d.hasAttribute('data-foo-bar'))"),
            "baz\nv fooBar,newKey\nfalse", "dataset")
    t.equal(c.run("var d = document.getElementById('d'); var at = d.attributes; console.log(at.length, at[0].name, at.title.value, d.getAttributeNode('title') === at.title); d.setAttribute('title', 'u'); console.log(at.title.value)"),
            "3 id t true\nu", "NamedNodeMap and Attr")
    t.equal(c.run("var x = new DOMParser().parseFromString('<p>a<template shadowrootmode=open><b>s</b></template></p>', 'text/html'); console.log(x.body.innerHTML, x.querySelector('p').shadowRoot)"),
            "<p>a<template shadowrootmode=\"open\"><b>s</b></template></p> null", "DOMParser leaves declarative shadow roots off")
    t.equal(c.run("var cl = document.getElementById('u').firstChild.classList; cl.add('b', 'c'); cl.remove('a'); console.log(cl.value, cl.contains('b'), cl.toggle('b'), cl.length); try { cl.add('') } catch (e) { console.log(e.name) }"),
            "b c true false 1\nSyntaxError", "classList")
    t.equal(c.run("try { document.querySelector('::bogus') } catch (e) { console.log(e.name) } try { document.querySelector('a:hover:has(b)') } catch (e) { console.log(e.name) } console.log(document.querySelectorAll(':scope li').length, document.getElementById('u').querySelectorAll(':scope > li').length)"),
            "SyntaxError\nSyntaxError\n3 3", "strict selectors and :scope")

    t.section("browser entry points")
    var focusLog: [String] = []
    var links: [String] = []
    let e = JSDOMTestPage("<body><a id=l href='/x'>x</a><input id=i value=a><div id=d onclick='console.log(\"div\", event.isTrusted, event.clientX)'>d</div></body>") { h in
        h.focusChanged = { n in focusLog.append(n?.attribute("id") ?? "none") }
        h.followHyperlink = { _, url, _ in links.append(url) }
    }
    _ = e.run("""
    document.addEventListener('DOMContentLoaded', function () { console.log('dcl', document.readyState) });
    window.addEventListener('load', function () { console.log('load', document.readyState) });
    document.getElementById('i').addEventListener('input', function (ev) { console.log('input', this.value, ev.inputType) });
    document.getElementById('l').addEventListener('click', function (ev) { if (window.blockLink) ev.preventDefault() });
    """)
    e.box.lines = []
    e.page.finishParsing()
    e.page.finishLoading()
    t.equal(e.box.lines.joined(separator: ","), "dcl interactive,load complete", "DOMContentLoaded and load")
    let doc = e.page.document
    func byID(_ id: String) -> HTMLNode { doc.firstElement { $0.attribute("id") == id }! }
    e.box.lines = []
    var info = JSDOMInputInfo()
    info.clientX = 12
    t.check(!e.page.dispatchMouse("click", at: byID("d"), info), "trusted click not canceled")
    t.equal(e.box.lines.joined(separator: ","), "div true 12", "trusted click reaches the onclick handler")
    e.page.dispatchMouse("click", at: byID("l"))
    _ = e.run("window.blockLink = true")
    t.check(e.page.dispatch(event: "click", kind: .pointer, to: byID("l")), "canceled click reports defaultPrevented")
    t.equal(links.joined(separator: ","), "https://example.test/x", "link default action only when not canceled")
    e.page.setFocus(byID("i"))
    e.box.lines = []
    e.page.setUserValue(byID("i"), "typed")
    t.equal(e.box.lines.joined(separator: ","), "input typed insertText", "user input sets the value and fires input")
    t.equal(e.page.controlValue(of: byID("i")), "typed", "controlValue")
    t.equal(e.run("console.log(document.activeElement.id)"), "i", "activeElement follows setFocus")
    t.equal(focusLog.joined(separator: ","), "i", "focusChanged hook")

    t.section("cost")
    let t0 = hostMillis()
    var k = 0
    while k < 10 {
        let d = htmlParse("<body><p>x")
        let pg = JSDOMPage(document: d, url: "https://example.test/", host: JSDOMHost())
        pg.tearDown()
        k += 1
    }
    let perPage = (hostMillis() - t0) / 10
    let probe = JSDOMPage(document: htmlParse("<body>"), url: "https://example.test/", host: JSDOMHost())
    var costLine = "js-dom: page setup " + String(perPage) + " ms, "
    costLine += String(probe.realm.natives.count) + " natives, "
    costLine += String(probe.realm.heap.objectCount) + " objects"
    print(costLine)
    t.check(perPage < 1000, "page setup is cheap enough (" + String(perPage) + " ms)")
    probe.tearDown()

    t.section("gc")
    let g = JSDOMTestPage("<body><div id=a></div>")
    g.page.realm.heap.gcEveryAllocation = true
    t.equal(g.run("""
    var d = document.createElement('div'); d.expando = 42; d.id = 'det';
    var keep = document.getElementById('a'); keep.foo = 'bar';
    d = null;
    for (var i = 0; i < 50; i++) document.createElement('span');
    console.log(document.getElementById('a').foo, document.getElementById('a') === keep);
    var p = document.createElement('p'); p.marker = 7; document.body.appendChild(p); p = null;
    for (var i = 0; i < 50; i++) ({});
    console.log(document.body.lastChild.marker);
    var ev = new CustomEvent('x', {detail: {v: 1}}); document.body.addEventListener('x', function (e) { console.log('detail', e.detail.v) }); document.body.dispatchEvent(ev);
    """), "bar true\n7\ndetail 1", "wrappers survive GC (connected / expandos / listeners)")
    g.page.realm.heap.gcEveryAllocation = false
}
