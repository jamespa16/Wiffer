// Vue 3 (lib/js/fixtures/corpus/vue-3.5.13.global.js, MIT) on a page with a
// layout engine (9J): an app with a template compiled at run time, v-for,
// v-model-free events and a computed property mounts, renders and
// re-renders after a click.

func jsdomVueTests(_ t: Tests) {
    t.section("vue")
    guard let vue = t.readFile("lib/js/fixtures/corpus/vue-3.5.13.global.js") else { return }
    let p = JSDOMLayoutPage(t, "<!DOCTYPE html><body><div id=app></div></body>", budgetMs: 20_000)
    func run(_ s: String, _ name: String = "vue-test.js") -> String {
        p.box.lines = []
        p.box.errors = []
        p.page.runScript(s, name: name)
        p.settle()
        var out = p.box.lines
        for e in p.box.errors { out.append("ERR: " + e) }
        var r = ""
        for (i, l) in out.enumerated() { if i > 0 { r += "\n" }; r += l }
        return r
    }
    let start = hostMillis()
    t.equal(run(String(decoding: vue, as: UTF8.self), "vue.js"), "You are running a development build of Vue.\nMake sure to use the production build (*.prod.js) when deploying for production.", "vue loads (its development-build notice)")
    let loaded = hostMillis()
    t.equal(run("""
        var app = Vue.createApp({
          data: function () { return { items: ['a', 'b'], n: 0 }; },
          computed: { total: function () { return this.items.length + this.n; } },
          template: '<ul><li v-for="x in items" :key="x" class="it">{{ x }}</li></ul><button id=b @click="items.push(\\'c\\'); n++">add</button><p id=t>{{ total }}</p>'
        });
        var vm = app.mount('#app');
        console.log(document.querySelectorAll('li.it').length, document.getElementById('t').textContent);
        """), "2 2", "vue mounts a compiled template")
    if let b = p.doc.body.flatMap({ body -> HTMLNode? in
        var found: HTMLNode? = nil
        body.walk { n in if n.isHTML("button") { found = n; return false }; return true }
        return found
    }) {
        p.page.dispatchMouse("click", at: b)
        p.settle()
    }
    t.equal(run("console.log(document.querySelectorAll('li.it').length, document.getElementById('t').textContent)"), "3 4",
            "vue re-renders after a click")
    print("js-dom vue: load \(loaded - start) ms, mount + click \(hostMillis() - loaded) ms")
    p.page.tearDown()
}
