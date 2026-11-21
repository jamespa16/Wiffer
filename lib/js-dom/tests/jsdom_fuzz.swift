// DOM fuzz (ROADMAP 9G/9J): random scripts drawn from a grammar of DOM
// calls run against fixture pages with a layout engine, then forced layout,
// a full update and paint. A trap, a hang or an engine invariant failure is the
// failure mode; script exceptions are expected and ignored.
//
//     WIFFER_JSDOM_FUZZ_SEED=n     first seed (default 1)
//     WIFFER_JSDOM_FUZZ_ROUNDS=n   scripts per page (default 6)

struct JSDOMFuzzGen {
    var rng: TestRandom

    mutating func pick<T>(_ xs: [T]) -> T { xs[rng.below(xs.count)] }
    mutating func int(_ n: Int) -> String { String(rng.below(n)) }

    mutating func tag() -> String { pick(["div", "span", "p", "a", "ul", "li", "table", "tr", "td", "input", "button", "img", "b", "section", "svg", "template", "slot", "select", "option", "textarea", "form", "label", "my-el"]) }
    mutating func attr() -> String { pick(["id", "class", "style", "href", "title", "hidden", "slot", "name", "type", "value", "onclick", "data-x", "colspan", "dir", "checked", "selected", "tabindex"]) }
    mutating func value() -> String {
        pick(["'a'", "'b c'", "''", "'display:none'", "'color:red; width: 30px'", "'float:left'", "'position:absolute; top:5px'",
              "'display:flex'", "'display:contents'", "'x'", "'1'", "'checkbox'", "'counter++'", "'<b>'", "'s1'", "'\\u00e9'",
              "String(Math.random())", "'margin: 10% 2em'", "'display: table-cell'"])
    }
    mutating func markup() -> String {
        pick(["'<b>x</b>y'", "'<p>one<p>two'", "'<table><td>c</table>'", "'<li>a<li>b'", "'text'", "''", "'<div style=\"float:right\">f</div>'",
              "'<template><i>t</i></template>'", "'<svg><circle r=3></circle></svg>'", "'<select><option>o</select>'",
              "'<span slot=s1>s</span>'", "'<a href=\"#x\" onclick=\"return false\">l</a>'", "'<input type=checkbox checked>'", "'&amp;&lt;'"])
    }
    mutating func selector() -> String {
        pick(["'*'", "'div'", "'p > span'", "'.a'", "'#a'", "'li:first-child'", "'div + p'", "'[data-x]'", "':not(div)'",
              "'td:nth-child(2n+1)'", "'a[href]'", "'section ~ p'", "':scope > *'", "'::before'", "'div:has(p)'", "'@bad'"])
    }
    mutating func el() -> String { "E(" + int(100_000) + ")" }
    /// An element (or the root) of a random open shadow tree.
    mutating func sh() -> String { "S(" + int(100_000) + ")" }

    mutating func statement() -> String {
        switch rng.below(40) {
        case 0: return el() + ".appendChild(" + el() + ")"
        case 1: return el() + ".insertBefore(" + el() + ", " + el() + ".firstChild)"
        case 2: return el() + ".remove()"
        case 3: return "var p = " + el() + ".parentNode; if (p) p.replaceChild(document.createElement('" + tag() + "'), " + el() + ")"
        case 4: return el() + ".setAttribute('" + attr() + "', " + value() + ")"
        case 5: return el() + ".removeAttribute('" + attr() + "')"
        case 6: return el() + ".classList.toggle('a')"
        case 7: return el() + ".style.setProperty('" + pick(["color", "display", "width", "margin-left", "float", "position", "transform"]) + "', " + value() + ")"
        case 8: return el() + ".innerHTML = " + markup()
        case 9: return el() + ".textContent = " + value()
        case 10: return el() + ".appendChild(" + el() + ".cloneNode(" + pick(["true", "false"]) + "))"
        case 11: return el() + ".insertAdjacentHTML('" + pick(["beforebegin", "afterbegin", "beforeend", "afterend"]) + "', " + markup() + ")"
        case 12: return el() + ".attachShadow({mode: '" + pick(["open", "closed"]) + "'}).innerHTML = '<slot name=s1></slot><slot></slot><p>sh</p>'"
        case 13: return el() + ".dispatchEvent(new MouseEvent('click', {bubbles: true}))"
        case 14: return "var r = " + el() + ".getBoundingClientRect(); sink += r.width + r.height"
        case 15: return "sink += getComputedStyle(" + el() + ").display.length"
        case 16: return "sink += document.querySelectorAll(" + selector() + ").length"
        case 17: return el() + ".normalize()"
        case 18: return "var t = document.createTextNode('abcdef'); " + el() + ".appendChild(t); t.splitText(" + int(8) + ")"
        case 19: return "new MutationObserver(function(rs) { sink += rs.length; " + el() + ".setAttribute('data-m', '1') }).observe(" + el() + ", {subtree: true, childList: true, attributes: true})"
        case 20: return el() + ".addEventListener('click', function(e) { e.target.remove(); " + el() + ".append('x') })"
        case 21: return el() + ".click()"
        case 22: return "sink += " + el() + ".offsetWidth + " + el() + ".scrollHeight + " + el() + ".clientWidth"
        case 23: return "document.body.append(document.createElement('" + tag() + "'), 'txt')"
        case 24: return el() + ".outerHTML = " + markup()
        case 25: return el() + ".replaceWith(" + el() + ", 'r')"
        case 26: return "sink += " + el() + ".matches(" + selector() + ") ? 1 : 0"
        case 27: return el() + ".before(document.createComment('c'))"
        case 28: return "var f = document.createDocumentFragment(); f.append(" + el() + ", " + el() + "); " + el() + ".prepend(f)"
        case 29: return "document.title = " + value()
        case 30: return el() + ".dataset.k = " + value()
        // 9I: custom elements, slots, adopted stylesheets.
        case 32:
            return "customElements.define('x-f' + " + int(4) + ", class extends HTMLElement { constructor() { super(); "
                + "if (" + int(2) + ") this.attachShadow({mode: 'open'}).innerHTML = '<slot name=s1></slot><slot></slot><b>c</b>' } "
                + "connectedCallback() { " + el() + ".setAttribute('data-c', '1') } "
                + "disconnectedCallback() { " + el() + ".append('d') } "
                + "attributeChangedCallback() { this.toggleAttribute('data-q') } "
                + "static get observedAttributes() { return ['title', 'class'] } })"
        case 33: return el() + ".appendChild(document.createElement('x-f" + int(4) + "'))"
        case 34: return el() + ".innerHTML = '<x-f0 title=a><span slot=s1>q</span></x-f0><x-f1 class=b></x-f1><x-f2></x-f2>'"
        case 35: return sh() + ".setAttribute('name', " + pick(["'s1'", "''", "'s2'"]) + ")"
        case 36: return sh() + ".appendChild(document.createElement('" + pick(["slot", "slot", "p", "x-f3"]) + "'))"
        case 37: return el() + ".attachShadow({mode: 'open', slotAssignment: 'manual'}).innerHTML = '<slot></slot><slot name=s1></slot>'; "
            + sh() + ".assign(" + el() + ", " + el() + ")"
        case 38:
            return "var sh = new CSSStyleSheet(); sh.replaceSync(" + pick(["'p { color: red } :host { display: block }'",
                "'::slotted(*) { margin: 2px } b { float: left }'", "'* { display: contents }'", "''"]) + "); "
                + pick(["S(" + int(100_000) + ").getRootNode()", "document"]) + ".adoptedStyleSheets = [sh]"
        case 39: return "customElements.upgrade(" + el() + "); " + el() + ".slot = 's1'; " + sh() + ".remove()"
        default: return "sink += " + el() + ".closest(" + selector() + ") ? 1 : 0"
        }
    }

    mutating func script(_ n: Int) -> String {
        var s = "var sink = 0; var all = function () { return document.querySelectorAll('*'); };\n"
        s += "function E(i) { var a = all(); if (a.length === 0) return document.body || document.documentElement; return a[i % a.length]; }\n"
        s += "function S(i) { var a = all(), hs = []; for (var k = 0; k < a.length; k++) if (a[k].shadowRoot) hs.push(a[k].shadowRoot); "
        s += "if (!hs.length) return E(i); var r = hs[i % hs.length], q = r.querySelectorAll('*'); return q.length ? q[i % q.length] : r; }\n"
        var k = 0
        while k < n {
            s += "try { " + statement() + " } catch (e) {}\n"
            k += 1
        }
        return s
    }
}

func jsdomFuzzTests(_ t: Tests) {
    t.section("fuzz")
    let pages = ["block", "flex", "floats", "inline", "lists", "position", "tables", "shadow", "pseudo", "replaced"]
    let seed = Int(jsdomEnv("WIFFER_JSDOM_FUZZ_SEED") ?? "") ?? 1
    let rounds = Int(jsdomEnv("WIFFER_JSDOM_FUZZ_ROUNDS") ?? "") ?? 6
    var scripts = 0
    var px = [UInt32](repeating: 0, count: 400 * 300)
    let start = hostMillis()
    for (pi, name) in pages.enumerated() {
        guard let html = t.readFile("lib/layout/fixtures/" + name + ".html") else { continue }
        host_guard_label("js-dom: fuzz " + name)
        let p = JSDOMLayoutPage(t, String(decoding: html, as: UTF8.self), width: 400, height: 300, budgetMs: 300)
        var gen = JSDOMFuzzGen(rng: TestRandom(seed: UInt64(seed * 1000 + pi)))
        var r = 0
        while r < rounds {
            let src = gen.script(40)
            p.page.runScript(src, name: "fuzz.js")
            p.settle()
            // Forced layout over everything, then a full update.
            p.doc.walk { n in
                if n.kind == .element { _ = p.engine.rect(of: n) }
                return true
            }
            p.engine.update()
            // And paint (9J: the fuzz covers layout and paint), scrolled
            // to the top and part way down.
            px.withUnsafeMutableBufferPointer { b in
                p.engine.paint(into: b.baseAddress!, stride: 400, width: 400, height: 300, scrollX: 0, scrollY: 0)
                p.engine.paint(into: b.baseAddress!, stride: 400, width: 400, height: 300, scrollX: 0, scrollY: Double(r * 40))
            }
            scripts += 1
            r += 1
        }
        p.page.tearDown()
    }
    t.check(scripts > 0, "dom fuzz ran " + String(scripts) + " scripts without trapping (" + String(hostMillis() - start) + " ms)")
}
