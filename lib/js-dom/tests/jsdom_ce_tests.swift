// Custom elements, shadow DOM from script, constructable stylesheets
// (ROADMAP Phase 9I).

func jsdomCETests(_ t: Tests) {
    t.section("custom elements")
    let p = JSDOMTestPage("<!DOCTYPE html><body><x-early id=e a=1>light</x-early><div id=host></div></body>")
    t.equal(p.run("""
        var log = [];
        class XEarly extends HTMLElement {
          static get observedAttributes() { return ['a', 'b']; }
          constructor() { super(); this.made = true; log.push('ctor ' + this.isConnected); }
          connectedCallback() { log.push('connected'); }
          disconnectedCallback() { log.push('disconnected'); }
          attributeChangedCallback(n, o, v, ns) { log.push('attr ' + n + ' ' + o + ' ' + v + ' ' + ns); }
        }
        var e = document.getElementById('e');
        console.log(e instanceof XEarly, e.matches(':defined'));
        customElements.define('x-early', XEarly);
        console.log(e instanceof XEarly, e.made, e.matches(':defined'), log.join(','));
        """), "false false\ntrue true true ctor true,attr a null 1 null,connected", "upgrade on define")
    t.equal(p.run("""
        log = [];
        e.setAttribute('b', '2'); e.setAttribute('c', '3'); e.removeAttribute('a');
        document.body.removeChild(e); document.body.appendChild(e);
        console.log(log.join(','));
        """), "attr b null 2 null,attr a 1 null null,disconnected,connected", "reactions")
    t.equal(p.run("""
        log = [];
        var c = document.createElement('x-early');
        console.log(c instanceof XEarly, c.made, log.join(','), customElements.get('x-early') === XEarly, customElements.getName(XEarly));
        var n = new XEarly(); console.log(n.localName, n.isConnected);
        """), "true true ctor false true x-early\nx-early false", "createElement constructs synchronously")
    t.equal(p.run("""
        try { customElements.define('x-early', class extends HTMLElement {}) } catch (e) { console.log(e.name) }
        try { customElements.define('nodash', class extends HTMLElement {}) } catch (e) { console.log(e.name) }
        try { customElements.define('x-b', class extends HTMLButtonElement {}, { extends: 'button' }) } catch (e) { console.log(e.name) }
        try { new HTMLElement() } catch (e) { console.log(e.name) }
        try { customElements.define('x-n', 5) } catch (e) { console.log(e.name) }
        """), "NotSupportedError\nSyntaxError\nNotSupportedError\nTypeError\nTypeError", "define validity checks")
    t.equal(p.run("""
        customElements.whenDefined('x-later').then(c => console.log('defined', c.name));
        customElements.whenDefined('bad').catch(e => console.log('rejected', e.name));
        class XLater extends HTMLElement {}
        customElements.define('x-later', XLater);
        """), "rejected SyntaxError\ndefined XLater", "whenDefined")
    t.equal(p.run("""
        log = [];
        class XShadow extends HTMLElement {
          constructor() { super(); this.attachShadow({mode: 'open'}).innerHTML = '<p>shadow <slot></slot></p><x-early></x-early>'; }
        }
        customElements.define('x-shadow', XShadow);
        var h = document.getElementById('host');
        h.innerHTML = '<x-shadow><b>slotted</b></x-shadow>';
        var s = h.firstChild;
        console.log(s.shadowRoot.querySelector('p').textContent, s.shadowRoot.querySelector('slot').assignedNodes()[0].tagName, log.join(','));
        """), "shadow  B ctor true,connected", "innerHTML upgrade + connected in shadow tree")
    t.equal(p.run("""
        var d = document.createElement('div');
        d.innerHTML = '<x-later></x-later>';
        console.log(d.firstChild instanceof XLater);
        document.body.appendChild(d);
        console.log(d.firstChild instanceof XLater);
        var tmpl = document.createElement('template'); tmpl.innerHTML = '<x-later></x-later>';
        var cl = document.importNode(tmpl.content, true);
        console.log(cl.firstChild instanceof XLater);
        var up = document.implementation.createHTMLDocument('').createElement('x-later');
        customElements.upgrade(up); console.log(up instanceof XLater);
        """), "false\ntrue\ntrue\nfalse", "fragment parsing, import, upgrade()")
    t.equal(p.run("""
        log = [];
        class XAdopt extends HTMLElement { adoptedCallback(o, n) { log.push('adopted ' + (o === document) + ' ' + (n === doc2)); } }
        customElements.define('x-adopt', XAdopt);
        var doc2 = document.implementation.createHTMLDocument('');
        var a = document.createElement('x-adopt'); document.body.appendChild(a);
        doc2.body.appendChild(a);
        console.log(log.join(','));
        """), "adopted true true", "adoptedCallback")
    t.equal(p.run("""
        class XThrow extends HTMLElement { constructor() { super(); throw new Error('boom'); } }
        customElements.define('x-throw', XThrow);
        var x = document.createElement('x-throw');
        console.log(x instanceof HTMLUnknownElement, x.matches(':defined'));
        """), "true false\nERR: Error: boom", "constructor exception reported")
    t.equal(p.run("""
        log = [];
        class XOrder extends HTMLElement { connectedCallback() { log.push(this.id); } }
        customElements.define('x-order', XOrder);
        document.body.insertAdjacentHTML('beforeend', '<x-order id=o1><x-order id=o2></x-order></x-order><x-order id=o3></x-order>');
        console.log(log.join(','));
        """), "o1,o2,o3", "document order")
    t.equal(p.run("""
        log = [];
        class XInt extends HTMLElement { constructor() { super(); this.i = this.attachInternals(); this.attachShadow({mode:'closed'}); } }
        customElements.define('x-int', XInt);
        var xi = document.createElement('x-int');
        console.log(xi.shadowRoot, xi.i.shadowRoot instanceof ShadowRoot);
        try { xi.attachInternals() } catch (e) { console.log(e.name) }
        """), "null true\nNotSupportedError", "attachInternals")

    t.section("shadow dom (js)")
    t.equal(p.run("""
        var host = document.createElement('div'); document.body.appendChild(host);
        var root = host.attachShadow({mode: 'open'});
        root.innerHTML = '<slot name=a></slot><span id=in>x</span>';
        var c = document.createElement('i'); c.slot = 'a'; host.appendChild(c);
        var path = [];
        root.getElementById('in').addEventListener('click', e => path = e.composedPath().map(n => n.nodeName || 'window'));
        root.getElementById('in').click();
        console.log(path.join(' '), root.getElementById('in').getRootNode() === root, root.getElementById('in').getRootNode({composed: true}) === document);
        console.log(document.getElementById('in'), document.querySelector('#in'));
        """), "SPAN #document-fragment DIV BODY HTML #document window true true\nnull null", "composedPath, getRootNode, queries stop at the boundary")
    t.equal(p.run("""
        var events = [];
        root.addEventListener('slotchange', e => events.push(e.target.name));
        var c2 = document.createElement('i'); c2.slot = 'a'; host.appendChild(c2);
        var c3 = document.createElement('i'); c3.slot = 'a'; host.appendChild(c3);
        Promise.resolve().then(() => console.log(events.join(','), root.querySelector('slot').assignedElements().length));
        """), "a 3", "slotchange deduplicated per microtask")

    t.section("constructable stylesheets")
    t.equal(p.run("""
        var sh = new CSSStyleSheet();
        sh.replaceSync('p { color: red } @media (min-width: 1px) { p { color: blue } } bad { ');
        console.log(sh.cssRules.length, sh.cssRules[0].cssText, sh.cssRules[0].selectorText, sh.cssRules[1].type);
        sh.insertRule('b { color: green }', 1); sh.deleteRule(0);
        console.log(sh.cssRules.length, sh.cssRules[0].selectorText, sh.cssRules[0].parentStyleSheet === sh);
        try { sh.insertRule('x {', 9) } catch (e) { console.log(e.name) }
        try { sh.insertRule('@import url(a.css);') } catch (e) { console.log(e.name) }
        root.adoptedStyleSheets = [sh];
        console.log(root.adoptedStyleSheets.length, root.adoptedStyleSheets[0] === sh, document.adoptedStyleSheets.length);
        try { document.adoptedStyleSheets = [1] } catch (e) { console.log(e.name) }
        sh.replace('i { color: red }').then(s => console.log('replaced', s === sh, s.cssRules.length));
        """), "3 p { color: red } p 4\n3 b true\nIndexSizeError\nSyntaxError\n1 true 0\nTypeError\nreplaced true 1",
        "CSSStyleSheet")

    t.section("focus")
    t.equal(p.run("""
        var fh = document.createElement('div'); document.body.appendChild(fh);
        var fr = fh.attachShadow({mode: 'open', delegatesFocus: true});
        fr.innerHTML = '<span>no</span><input id=inp>';
        fh.focus();
        console.log(document.activeElement === fh, fr.activeElement === fr.getElementById('inp'), fh.matches(':focus-within'), document.body.matches(':focus-within'), fh.matches(':focus'));
        """), "true true true true true", "delegatesFocus, activeElement, :focus-within, :focus on the host")
}

/// lit-core's ES module as a classic script: the final `export{a as B,...}`
/// becomes `globalThis.Lit = {B: a, ...}`.
func jsdomLitClassic(_ src: [UInt8]) -> String? {
    let marker = Array("export{".utf8)
    var at = -1
    var i = src.count - marker.count
    while i >= 0 {
        if Array(src[i..<i + marker.count]) == marker { at = i; break }
        i -= 1
    }
    if at < 0 { return nil }
    var j = at + marker.count
    while j < src.count && src[j] != 0x7d { j += 1 }
    if j >= src.count { return nil }
    let list = String(decoding: src[(at + marker.count)..<j], as: UTF8.self)
    var obj = "globalThis.Lit={"
    for (k, item) in list.split(separator: ",").enumerated() {
        let parts = item.split(separator: " ")
        guard parts.count == 3 else { return nil }
        if k > 0 { obj += "," }
        obj += parts[2] + ":" + parts[0]
    }
    obj += "}"
    // In a function: its top-level consts must not become globals.
    return "(function(){" + String(decoding: src[0..<at], as: UTF8.self) + obj + String(decoding: src[(j + 1)...], as: UTF8.self) + "\n})();"
}

/// A counter component built with lit-core 3.2.1 (lib/js/fixtures/corpus,
/// BSD-3-Clause): it renders a shadow tree styled by adoptedStyleSheets and
/// re-renders after clicks dispatched at its button.
func jsdomLitTests(_ t: Tests) {
    t.section("lit")
    guard let bytes = t.readFile("lib/js/fixtures/corpus/lit-core-3.2.1.min.module.js"), let lit = jsdomLitClassic(bytes) else {
        t.check(false, "lit-core fixture")
        return
    }
    let p = JSDOMLayoutPage(t, "<!DOCTYPE html><body><x-counter id=c></x-counter><p>after</p></body>")
    func run(_ s: String) -> String {
        p.box.lines = []
        p.box.errors = []
        p.page.runScript(s, name: "lit-test.js")
        p.settle()
        var out = p.box.lines
        for e in p.box.errors { out.append("ERR: " + e) }
        var r = ""
        for (i, l) in out.enumerated() { if i > 0 { r += "\n" }; r += l }
        return r
    }
    t.equal(run(lit), "", "lit-core loads")
    t.equal(run("""
        const {LitElement, html, css} = Lit;
        class XCounter extends LitElement {
          static properties = { count: { type: Number } };
          static styles = css`:host { display: block; padding: 4px } button { color: rgb(0, 128, 0) } p { margin: 0 }`;
          constructor() { super(); this.count = 0; }
          render() { return html`<p>Count: ${this.count}</p><button @click=${() => { this.count++; }}>+1</button>`; }
        }
        customElements.define('x-counter', XCounter);
        console.log(Lit.supportsAdoptingStyleSheets);
        """), "true", "define a LitElement")
    t.equal(run("""
        var c = document.getElementById('c');
        console.log(c instanceof Lit.LitElement, c.shadowRoot.querySelector('p').textContent,
                    c.shadowRoot.adoptedStyleSheets.length, c.shadowRoot.adoptedStyleSheets[0].cssRules.length,
                    getComputedStyle(c.shadowRoot.querySelector('button')).color, getComputedStyle(c).display);
        """), "true Count: 0 1 3 rgb(0, 128, 0) block", "renders a shadow tree with adoptedStyleSheets")
    var button: HTMLNode? = nil
    if let host = p.doc.body?.children.first, let root = host.attachedShadowRoot {
        root.walk { n in
            if n.isHTML("button") { button = n; return false }
            return true
        }
    }
    t.check(button != nil, "lit: the button is in the shadow tree")
    if let b = button {
        p.page.dispatchMouse("click", at: b)
        p.settle()
        p.page.dispatchMouse("click", at: b)
        p.settle()
    }
    t.equal(run("console.log(c.count, c.shadowRoot.querySelector('p').textContent, c.updateComplete instanceof Promise)"),
            "2 Count: 2 true", "reacts to dispatched clicks")
    // The engine renders the flat tree: the shadow paragraph has a box.
    var shadowP: HTMLNode? = nil
    button?.parent?.walk { n in
        if n.isHTML("p") { shadowP = n; return false }
        return true
    }
    p.engine.update()
    t.check(shadowP.flatMap { p.engine.box(for: $0) } != nil, "lit: shadow content is laid out")
}
