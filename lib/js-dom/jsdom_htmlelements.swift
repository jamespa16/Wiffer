// HTML element interfaces with behavior: links (HTMLHyperlinkElementUtils),
// forms and their controls (value / checkedness / selectedness state,
// validity, submission through JSDOMHost.submitForm), activation behavior
// for clicks, images, templates, slots, tables, dialogs, media stubs.
//
// Control state the DOM owns (the "dirty value", checkedness, selectedness)
// lives in `controls` (JSDOMControlState per element). The browser reads it
// with JSDOMPage.controlValue(of:) / controlChecked(of:) when painting and
// writes user edits with JSDOMPage.setUserValue(_:_:) / setUserChecked.

extension JSDOMBindings {
    func control(_ n: HTMLNode) -> JSDOMControlState {
        let k = ObjectIdentifier(n)
        if let c = controls[k] { return c }
        let c = JSDOMControlState()
        controls[k] = c
        return c
    }

    func controlChanged(_ n: HTMLNode) { host.controlChanged(n) }

    func copyControlState(from a: HTMLNode, to b: HTMLNode, deep: Bool) {
        if controls.isEmpty { return }
        var sa: [HTMLNode] = [a], sb: [HTMLNode] = [b]
        while let x = sa.popLast(), let y = sb.popLast() {
            if let c = controls[ObjectIdentifier(x)] {
                let d = control(y)
                d.value = c.value; d.checked = c.checked; d.selected = c.selected; d.indeterminate = c.indeterminate
            }
            if !deep { break }
            if x.children.count == y.children.count {
                sa.append(contentsOf: x.children)
                sb.append(contentsOf: y.children)
            }
        }
    }

    // MARK: Shared helpers

    func inputType(_ n: HTMLNode) -> String {
        let t = htmlLowerASCII(n.attribute("type") ?? "")
        switch t {
        case "hidden", "text", "search", "tel", "url", "email", "password", "date", "month", "week", "time",
             "datetime-local", "number", "range", "color", "checkbox", "radio", "file", "submit", "image", "reset",
             "button":
            return t
        default: return "text"
        }
    }

    func formOwner(_ n: HTMLNode) -> HTMLNode? {
        guard n.kind == .element, n.namespace == .html else { return nil }
        if let id = n.attribute("form"), jsdomIsListedElement(n) {
            let root = n.rootNode
            return descendantsMatching(root) { $0.attribute("id") == id }.first.flatMap { $0.isHTML("form") ? $0 : nil }
        }
        var x = n.parent
        while let p = x {
            if p.isHTML("form") { return p }
            x = p.parent
        }
        return nil
    }

    func isDisabled(_ n: HTMLNode) -> Bool {
        guard n.kind == .element, n.namespace == .html else { return false }
        switch n.name {
        case "button", "input", "select", "textarea", "fieldset", "optgroup":
            if n.hasAttribute("disabled") { return true }
            if n.name == "optgroup" { return false }
            // A disabled fieldset ancestor (except inside its first legend).
            var x = n.parent
            var child = n
            while let p = x {
                if p.isHTML("fieldset") && p.hasAttribute("disabled") {
                    let firstLegend = p.children.first { $0.isHTML("legend") }
                    if firstLegend !== child { return true }
                }
                child = p
                x = p.parent
            }
            return false
        case "option":
            if n.hasAttribute("disabled") { return true }
            if let p = n.parent, p.isHTML("optgroup"), p.hasAttribute("disabled") { return true }
            return false
        default: return false
        }
    }

    func inputChecked(_ n: HTMLNode) -> Bool {
        if let c = controls[ObjectIdentifier(n)], let v = c.checked { return v }
        return n.hasAttribute("checked")
    }

    func setInputChecked(_ n: HTMLNode, _ v: Bool) {
        control(n).checked = v
        if v && inputType(n) == "radio" { uncheckRadioGroup(n) }
        controlChanged(n)
    }

    func radioGroup(_ n: HTMLNode) -> [HTMLNode] {
        guard let name = n.attribute("name"), !name.isEmpty else { return [] }
        let form = formOwner(n)
        let root = form ?? n.rootNode
        return descendantsMatching(root) { x in
            x.isHTML("input") && self.inputType(x) == "radio" && x.attribute("name") == name && x !== n && self.formOwner(x) === form
        }
    }

    func uncheckRadioGroup(_ n: HTMLNode) {
        for r in radioGroup(n) where inputChecked(r) { control(r).checked = false; controlChanged(r) }
    }

    func selectOptions(_ s: HTMLNode) -> [HTMLNode] {
        var out: [HTMLNode] = []
        for c in s.children {
            if c.isHTML("option") { out.append(c) }
            else if c.isHTML("optgroup") { for o in c.children where o.isHTML("option") { out.append(o) } }
        }
        return out
    }

    func optionSelect(_ o: HTMLNode) -> HTMLNode? {
        var x = o.parent
        if let p = x, p.isHTML("optgroup") { x = p.parent }
        if let p = x, p.isHTML("select") { return p }
        return nil
    }

    func optionSelected(_ o: HTMLNode) -> Bool {
        if let s = optionSelect(o), !s.hasAttribute("multiple") {
            return displayedSelection(s) === o
        }
        if let c = controls[ObjectIdentifier(o)], let v = c.selected { return v }
        return o.hasAttribute("selected")
    }

    /// The selected option of a single select: the last one marked
    /// selected, else the first non-disabled one.
    func displayedSelection(_ s: HTMLNode) -> HTMLNode? {
        let opts = selectOptions(s)
        var pick: HTMLNode? = nil
        for o in opts {
            let explicit = controls[ObjectIdentifier(o)]?.selected ?? (o.hasAttribute("selected") ? true : nil)
            if explicit == true { pick = o }
        }
        if pick == nil {
            let size = s.attribute("size").flatMap { jsdomParseInteger($0) } ?? 1
            if size <= 1 { pick = opts.first { !self.isDisabled($0) } }
        }
        return pick
    }

    func setOptionSelected(_ o: HTMLNode, _ v: Bool) {
        if let s = optionSelect(o), !s.hasAttribute("multiple"), v {
            for x in selectOptions(s) where x !== o { control(x).selected = false }
        }
        control(o).selected = v
        if let s = optionSelect(o) { controlChanged(s) }
    }

    // MARK: Links (HTMLHyperlinkElementUtils)

    func linkURL(_ n: HTMLNode) -> URLRecord? {
        guard let h = n.attribute("href") else { return nil }
        if let b = baseURL { return b.resolve(h) }
        return URLRecord.parseOrNil(h)
    }

    func HTMLHyperlinkElementUtils_href(_ n: HTMLNode) -> String {
        guard let h = n.attribute("href") else { return "" }
        return linkURL(n)?.href ?? h
    }
    func HTMLHyperlinkElementUtils_set_href(_ n: HTMLNode, _ v: String) { n.setAttributeValue("href", v) }
    func HTMLHyperlinkElementUtils_origin(_ n: HTMLNode) -> String { linkURL(n)?.origin ?? "" }
    func HTMLHyperlinkElementUtils_protocol(_ n: HTMLNode) -> String { linkURL(n)?.protocolString ?? ":" }
    func HTMLHyperlinkElementUtils_username(_ n: HTMLNode) -> String { linkURL(n).map { String(decoding: $0.username, as: UTF8.self) } ?? "" }
    func HTMLHyperlinkElementUtils_password(_ n: HTMLNode) -> String { linkURL(n).map { String(decoding: $0.password, as: UTF8.self) } ?? "" }
    func HTMLHyperlinkElementUtils_host(_ n: HTMLNode) -> String { linkURL(n)?.hostWithPort ?? "" }
    func HTMLHyperlinkElementUtils_hostname(_ n: HTMLNode) -> String { linkURL(n)?.hostname ?? "" }
    func HTMLHyperlinkElementUtils_port(_ n: HTMLNode) -> String { linkURL(n)?.portString ?? "" }
    func HTMLHyperlinkElementUtils_pathname(_ n: HTMLNode) -> String { linkURL(n)?.pathname ?? "" }
    func HTMLHyperlinkElementUtils_search(_ n: HTMLNode) -> String { linkURL(n)?.search ?? "" }
    func HTMLHyperlinkElementUtils_hash(_ n: HTMLNode) -> String { linkURL(n)?.hash ?? "" }

    func updateLink(_ n: HTMLNode, _ f: (inout URLRecord) -> Void) {
        guard var u = linkURL(n) else { return }
        f(&u)
        n.setAttributeValue("href", u.href)
    }
    func HTMLHyperlinkElementUtils_set_protocol(_ n: HTMLNode, _ v: String) {
        updateLink(n) { u in
            var s = Array(v.utf8)
            if let i = s.firstIndex(of: 0x3a) { s = Array(s[..<i]) }
            if !s.isEmpty { u.scheme = s.map { $0 >= 0x41 && $0 <= 0x5a ? $0 + 0x20 : $0 } }
        }
    }
    func HTMLHyperlinkElementUtils_set_username(_ n: HTMLNode, _ v: String) { updateLink(n) { $0.username = Array(v.utf8) } }
    func HTMLHyperlinkElementUtils_set_password(_ n: HTMLNode, _ v: String) { updateLink(n) { $0.password = Array(v.utf8) } }
    func HTMLHyperlinkElementUtils_set_host(_ n: HTMLNode, _ v: String) { setLinkPart(n, host: v) }
    func HTMLHyperlinkElementUtils_set_hostname(_ n: HTMLNode, _ v: String) { setLinkPart(n, host: v) }
    func HTMLHyperlinkElementUtils_set_port(_ n: HTMLNode, _ v: String) {
        updateLink(n) { u in u.port = v.isEmpty ? nil : UInt16(jsdomParseInteger(v).map { min(max($0, 0), 65535) } ?? 0) }
    }
    func HTMLHyperlinkElementUtils_set_pathname(_ n: HTMLNode, _ v: String) { setLinkPart(n, path: v) }
    func HTMLHyperlinkElementUtils_set_search(_ n: HTMLNode, _ v: String) {
        updateLink(n) { u in
            var s = Array(v.utf8)
            if s.first == 0x3f { s.removeFirst() }
            u.query = s.isEmpty ? nil : s
        }
    }
    func HTMLHyperlinkElementUtils_set_hash(_ n: HTMLNode, _ v: String) {
        updateLink(n) { u in
            var s = Array(v.utf8)
            if s.first == 0x23 { s.removeFirst() }
            u.fragment = s.isEmpty ? nil : s
        }
    }

    /// Host and path setters: rebuild the URL text and reparse.
    func setLinkPart(_ n: HTMLNode, host: String? = nil, path: String? = nil) {
        guard let u = linkURL(n) else { return }
        var s = u.protocolString + "//"
        s += host ?? u.hostWithPort
        if let p = path { s += p.hasPrefix("/") ? p : "/" + p } else { s += u.pathname }
        s += u.search + u.hash
        if let nu = URLRecord.parseOrNil(s) { n.setAttributeValue("href", nu.href) }
    }

    func HTMLAnchorElement_relList(_ n: HTMLNode) -> JSValue { tokenList(n, "rel") }
    func HTMLAnchorElement_text(_ n: HTMLNode) -> String { Node_textContent(n) ?? "" }
    func HTMLAnchorElement_set_text(_ n: HTMLNode, _ v: String) { n.setTextContent(v) }

    // MARK: Forms

    func HTMLFormElement_action(_ n: HTMLNode) -> String {
        guard let a = n.attribute("action"), !a.isEmpty else { return url?.href ?? "" }
        return resolveURL(a) ?? a
    }
    func HTMLFormElement_set_action(_ n: HTMLNode, _ v: String) { n.setAttributeValue("action", v) }
    func HTMLFormElement_enctype(_ n: HTMLNode) -> String {
        switch htmlLowerASCII(n.attribute("enctype") ?? "") {
        case "multipart/form-data": return "multipart/form-data"
        case "text/plain": return "text/plain"
        default: return "application/x-www-form-urlencoded"
        }
    }
    func HTMLFormElement_set_enctype(_ n: HTMLNode, _ v: String) { n.setAttributeValue("enctype", v) }
    func HTMLFormElement_method(_ n: HTMLNode) -> String {
        switch htmlLowerASCII(n.attribute("method") ?? "") {
        case "post": return "post"
        case "dialog": return "dialog"
        default: return "get"
        }
    }
    func HTMLFormElement_set_method(_ n: HTMLNode, _ v: String) { n.setAttributeValue("method", v) }
    func HTMLFormElement_elements(_ n: HTMLNode) -> JSValue { makeCollection(n, .formElements) }
    func HTMLFormElement_length(_ n: HTMLNode) -> Int { computeCollection(JSDOMHTMLCollection(n, .formElements)).count }

    func HTMLFormElement_submit(_ n: HTMLNode) throws(JSThrow) {
        host.submitForm(n, nil)
    }

    func HTMLFormElement_requestSubmit(_ n: HTMLNode, _ submitter: HTMLNode?) throws(JSThrow) {
        if let s = submitter {
            if !isSubmitButton(s) { throw realm.throwTypeError("The specified element is not a submit button.") }
            if formOwner(s) !== n { throw throwDOM("NotFoundError", "The specified element is not owned by this form element.") }
        }
        submitForm(n, submitter: submitter)
    }

    func isSubmitButton(_ n: HTMLNode) -> Bool {
        if n.isHTML("button") { return HTMLButtonElement_type(n) == "submit" }
        if n.isHTML("input") { let t = inputType(n); return t == "submit" || t == "image" }
        return false
    }

    /// HTML "submit" from a submitter: validate (unless novalidate), fire
    /// `submit`, then hand the form to the browser unless canceled.
    func submitForm(_ form: HTMLNode, submitter: HTMLNode?) {
        if submitting.contains(ObjectIdentifier(form)) { return }
        submitting.insert(ObjectIdentifier(form))
        defer { submitting.remove(ObjectIdentifier(form)) }
        let noValidate = form.hasAttribute("novalidate") || (submitter?.hasAttribute("formnovalidate") ?? false)
        if !noValidate && !HTMLFormElement_reportValidity(form) { return }
        let e = JSDOMEvent(.SubmitEvent, type: "submit", time: now())
        e.bubbles = true
        e.cancelable = true
        e.isTrusted = true
        e.submitter = submitter
        let canceled = (try? dispatch(e, to: .node(form))) ?? true
        if !canceled { host.submitForm(form, submitter) }
    }

    func HTMLFormElement_reset(_ n: HTMLNode) {
        let e = JSDOMEvent(.Event, type: "reset", time: now())
        e.bubbles = true
        e.cancelable = true
        e.isTrusted = true
        let canceled = (try? dispatch(e, to: .node(n))) ?? true
        if canceled { return }
        for c in computeCollection(JSDOMHTMLCollection(n, .formElements)) {
            controls[ObjectIdentifier(c)] = nil
            if c.isHTML("select") { for o in selectOptions(c) { controls[ObjectIdentifier(o)] = nil } }
            controlChanged(c)
        }
    }

    func HTMLFormElement_checkValidity(_ n: HTMLNode) -> Bool {
        var ok = true
        for c in computeCollection(JSDOMHTMLCollection(n, .formElements)) where !HTMLInputElement_checkValidity(c) { ok = false }
        return ok
    }
    func HTMLFormElement_reportValidity(_ n: HTMLNode) -> Bool { HTMLFormElement_checkValidity(n) }

    func HTMLFieldSetElement_elements(_ n: HTMLNode) -> JSValue { makeCollection(n, .fieldsetElements) }

    // MARK: input

    func HTMLInputElement_type(_ n: HTMLNode) -> String { inputType(n) }
    func HTMLInputElement_set_type(_ n: HTMLNode, _ v: String) { n.setAttributeValue("type", v) }
    func HTMLInputElement_form(_ n: HTMLNode) -> HTMLNode? { formOwner(n) }
    func HTMLButtonElement_form(_ n: HTMLNode) -> HTMLNode? { formOwner(n) }
    func HTMLOptionElement_form(_ n: HTMLNode) -> HTMLNode? { optionSelect(n).flatMap { formOwner($0) } }
    func HTMLLabelElement_form(_ n: HTMLNode) -> HTMLNode? { HTMLLabelElement_control(n).flatMap { formOwner($0) } }

    enum ValueMode { case value, defaultMode, defaultOn, filename }

    func valueMode(_ n: HTMLNode) -> ValueMode {
        switch inputType(n) {
        case "hidden", "submit", "image", "reset", "button": return .defaultMode
        case "checkbox", "radio": return .defaultOn
        case "file": return .filename
        default: return .value
        }
    }

    func HTMLInputElement_value(_ n: HTMLNode) throws(JSThrow) -> String { inputValue(n) }

    func inputValue(_ n: HTMLNode) -> String {
        switch valueMode(n) {
        case .value:
            let raw = controls[ObjectIdentifier(n)]?.value ?? (n.attribute("value") ?? "")
            return sanitizeValue(n, raw)
        case .defaultMode: return n.attribute("value") ?? ""
        case .defaultOn: return n.attribute("value") ?? "on"
        case .filename: return ""
        }
    }

    func sanitizeValue(_ n: HTMLNode, _ v: String) -> String {
        switch inputType(n) {
        case "text", "search", "tel", "password":
            var out: [UInt8] = []
            for b in v.utf8 where b != 0x0a && b != 0x0d { out.append(b) }
            return String(decoding: out, as: UTF8.self)
        case "email", "url":
            return jsdomStripCollapse(v) == v ? v : String(v.utf8.filter { $0 != 0x0a && $0 != 0x0d }.map { Character(Unicode.Scalar($0)) })
        case "number":
            return jsdomParseFloat(v) != nil ? v : ""
        case "color":
            let l = htmlLowerASCII(v)
            if l.utf8.count == 7, l.utf8.first == 0x23, l.utf8.dropFirst().allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) { return l }
            return "#000000"
        case "range":
            let mn = n.attribute("min").flatMap { jsdomParseFloat($0) } ?? 0
            let mx = n.attribute("max").flatMap { jsdomParseFloat($0) } ?? 100
            var d = jsdomParseFloat(v) ?? (mx < mn ? mn : mn + (mx - mn) / 2)
            if d < mn { d = mn }
            if d > mx && mx >= mn { d = mx }
            return jsdomFormatNumber(d)
        default:
            return v
        }
    }

    func HTMLInputElement_set_value(_ n: HTMLNode, _ v: String) throws(JSThrow) {
        switch valueMode(n) {
        case .value:
            let c = control(n)
            c.value = v
            let len = sanitizeValue(n, v).utf16.count
            c.selectionStart = len
            c.selectionEnd = len
            controlChanged(n)
        case .defaultMode, .defaultOn: n.setAttributeValue("value", v)
        case .filename:
            if !v.isEmpty { throw throwDOM("InvalidStateError", "This input element accepts a filename, which may only be programmatically set to the empty string.") }
        }
    }

    func HTMLInputElement_valueAsNumber(_ n: HTMLNode) -> Double {
        switch inputType(n) {
        case "number", "range": return jsdomParseFloat(inputValue(n)) ?? .nan
        default: return .nan
        }
    }
    func HTMLInputElement_set_valueAsNumber(_ n: HTMLNode, _ v: Double) {
        if inputType(n) == "number" || inputType(n) == "range" { _ = try? HTMLInputElement_set_value(n, v.isNaN ? "" : jsdomFormatNumber(v)) }
    }

    func HTMLInputElement_checked(_ n: HTMLNode) -> Bool { inputChecked(n) }
    func HTMLInputElement_set_checked(_ n: HTMLNode, _ v: Bool) { setInputChecked(n, v) }
    func HTMLInputElement_indeterminate(_ n: HTMLNode) -> Bool { controls[ObjectIdentifier(n)]?.indeterminate ?? false }
    func HTMLInputElement_set_indeterminate(_ n: HTMLNode, _ v: Bool) { control(n).indeterminate = v; controlChanged(n) }
    func HTMLInputElement_files(_ n: HTMLNode) -> JSValue { inputType(n) == "file" ? array([]) : .null }

    func HTMLInputElement_willValidate(_ n: HTMLNode) -> Bool {
        if isDisabled(n) || n.hasAttribute("readonly") && n.isHTML("input") { return false }
        if n.isHTML("input") { let t = inputType(n); return t != "hidden" && t != "reset" && t != "button" }
        if n.isHTML("button") { return HTMLButtonElement_type(n) == "submit" }
        var x = n.parent
        while let p = x { if p.isHTML("datalist") { return false }; x = p.parent }
        return true
    }
    func HTMLButtonElement_willValidate(_ n: HTMLNode) -> Bool { HTMLInputElement_willValidate(n) }

    /// Validity: valueMissing, typeMismatch (email/url), patternMismatch,
    /// tooLong, rangeUnderflow/Overflow, customError.
    func validityFlags(_ n: HTMLNode) -> [(String, Bool)] {
        var flags: [(String, Bool)] = []
        let custom = !(controls[ObjectIdentifier(n)]?.customValidity ?? "").isEmpty
        var missing = false, typeMismatch = false, pattern = false, tooLong = false, under = false, over = false
        if HTMLInputElement_willValidate(n) {
            if n.isHTML("input") {
                let t = inputType(n)
                let v = inputValue(n)
                if n.hasAttribute("required") {
                    if t == "checkbox" { missing = !inputChecked(n) }
                    else if t == "radio" { missing = !inputChecked(n) && !radioGroup(n).contains { self.inputChecked($0) } }
                    else if t == "file" { missing = true }
                    else { missing = v.isEmpty }
                }
                if !v.isEmpty {
                    if t == "email" { typeMismatch = !jsdomLooksLikeEmail(v) }
                    if t == "url" { typeMismatch = URLRecord.parseOrNil(v) == nil }
                    if let p = n.attribute("pattern"), !p.isEmpty, t != "checkbox" && t != "radio" {
                        pattern = !regexFullMatch(p, v)
                    }
                    if t == "number" || t == "range", let d = jsdomParseFloat(v) {
                        if let mn = n.attribute("min").flatMap({ jsdomParseFloat($0) }), d < mn { under = true }
                        if let mx = n.attribute("max").flatMap({ jsdomParseFloat($0) }), d > mx { over = true }
                    }
                    if let ml = n.attribute("maxlength").flatMap({ jsdomParseInteger($0) }), ml >= 0,
                       controls[ObjectIdentifier(n)]?.value != nil, v.utf16.count > ml { tooLong = true }
                }
            } else if n.isHTML("select") {
                if n.hasAttribute("required") {
                    let sel = selectOptions(n).filter { self.optionSelected($0) }
                    missing = sel.isEmpty || (sel.count == 1 && HTMLOptionElement_value(sel[0]).isEmpty && !n.hasAttribute("multiple")
                                              && selectOptions(n).first === sel[0])
                }
            } else if n.isHTML("textarea") {
                if n.hasAttribute("required") { missing = HTMLTextAreaElement_value(n).isEmpty }
            }
        }
        flags.append(("valueMissing", missing))
        flags.append(("typeMismatch", typeMismatch))
        flags.append(("patternMismatch", pattern))
        flags.append(("tooLong", tooLong))
        flags.append(("tooShort", false))
        flags.append(("rangeUnderflow", under))
        flags.append(("rangeOverflow", over))
        flags.append(("stepMismatch", false))
        flags.append(("badInput", false))
        flags.append(("customError", custom))
        var valid = true
        for (_, f) in flags where f { valid = false }
        flags.append(("valid", valid))
        return flags
    }

    func regexFullMatch(_ pattern: String, _ v: String) -> Bool {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        let src = "(function(p, v) { try { return new RegExp('^(?:' + p + ')$', 'v').test(v); } catch (e) { return true; } })"
        guard case .normal(let f) = realm.evaluate(source: src, name: "pattern") else { return true }
        _ = heap.root(f)
        let ps = str(pattern), vs = str(v)
        _ = heap.root(ps); _ = heap.root(vs)
        if case .normal(let r) = realm.runCallback(f, this: .undefined, args: [ps, vs]) { return r == .true }
        return true
    }

    func HTMLInputElement_validity(_ n: HTMLNode) -> JSValue {
        let o = newObject()
        let d = heap.rootDepth
        _ = heap.root(o)
        for (k, v) in validityFlags(n) { setProp(o, k, .bool(v)) }
        heap.popRoots(to: d)
        return o
    }
    func HTMLButtonElement_validity(_ n: HTMLNode) -> JSValue { HTMLInputElement_validity(n) }

    func HTMLInputElement_validationMessage(_ n: HTMLNode) -> String {
        if let c = controls[ObjectIdentifier(n)], !c.customValidity.isEmpty { return c.customValidity }
        for (k, v) in validityFlags(n) where v && k != "valid" {
            switch k {
            case "valueMissing": return "Please fill out this field."
            case "typeMismatch": return "Please enter a valid value."
            case "patternMismatch": return "Please match the requested format."
            case "rangeUnderflow", "rangeOverflow": return "Value out of range."
            default: return "Invalid value."
            }
        }
        return ""
    }
    func HTMLButtonElement_validationMessage(_ n: HTMLNode) -> String { HTMLInputElement_validationMessage(n) }

    func HTMLInputElement_checkValidity(_ n: HTMLNode) -> Bool {
        for (k, v) in validityFlags(n) where k == "valid" {
            if !v {
                let e = JSDOMEvent(.Event, type: "invalid", time: now())
                e.cancelable = true
                e.isTrusted = true
                _ = try? dispatch(e, to: .node(n))
            }
            return v
        }
        return true
    }
    func HTMLInputElement_reportValidity(_ n: HTMLNode) -> Bool { HTMLInputElement_checkValidity(n) }
    func HTMLInputElement_setCustomValidity(_ n: HTMLNode, _ msg: String) { control(n).customValidity = msg }

    func HTMLInputElement_labels(_ n: HTMLNode) -> JSValue {
        let root = n.rootNode
        let labels = descendantsMatching(root) { $0.isHTML("label") && self.HTMLLabelElement_control($0) === n }
        return staticNodeList(labels)
    }

    func HTMLInputElement_select(_ n: HTMLNode) {
        let c = control(n)
        c.selectionStart = 0
        c.selectionEnd = (n.isHTML("textarea") ? HTMLTextAreaElement_value(n) : inputValue(n)).utf16.count
        let e = JSDOMEvent(.Event, type: "select", time: now())
        e.bubbles = true
        e.isTrusted = true
        _ = try? dispatch(e, to: .node(n))
    }
    func hasSelection(_ n: HTMLNode) -> Bool {
        if n.isHTML("textarea") { return true }
        switch inputType(n) {
        case "text", "search", "url", "tel", "password": return true
        default: return false
        }
    }
    func HTMLInputElement_selectionStart(_ n: HTMLNode) -> Int? { hasSelection(n) ? control(n).selectionStart : nil }
    func HTMLInputElement_selectionEnd(_ n: HTMLNode) -> Int? { hasSelection(n) ? control(n).selectionEnd : nil }
    func HTMLInputElement_set_selectionStart(_ n: HTMLNode, _ v: Int?) {
        let c = control(n)
        c.selectionStart = v ?? 0
        if c.selectionEnd < c.selectionStart { c.selectionEnd = c.selectionStart }
    }
    func HTMLInputElement_set_selectionEnd(_ n: HTMLNode, _ v: Int?) { control(n).selectionEnd = v ?? 0 }
    func HTMLInputElement_selectionDirection(_ n: HTMLNode) -> String? { hasSelection(n) ? "none" : nil }
    func HTMLInputElement_set_selectionDirection(_ n: HTMLNode, _ v: String?) {}
    func HTMLInputElement_setSelectionRange(_ n: HTMLNode, _ s: Int, _ e: Int, _ dir: String?) {
        let c = control(n)
        c.selectionStart = min(s, e)
        c.selectionEnd = e
    }
    func HTMLInputElement_stepUp(_ n: HTMLNode, _ k: Int) { stepBy(n, Double(k)) }
    func HTMLInputElement_stepDown(_ n: HTMLNode, _ k: Int) { stepBy(n, -Double(k)) }
    func stepBy(_ n: HTMLNode, _ k: Double) {
        let step = n.attribute("step").flatMap { jsdomParseFloat($0) } ?? 1
        let cur = jsdomParseFloat(inputValue(n)) ?? 0
        _ = try? HTMLInputElement_set_value(n, jsdomFormatNumber(cur + k * step))
    }
    func HTMLInputElement_showPicker(_ n: HTMLNode) {}

    // MARK: button

    func HTMLButtonElement_type(_ n: HTMLNode) -> String {
        switch htmlLowerASCII(n.attribute("type") ?? "") {
        case "reset": return "reset"
        case "button": return "button"
        default: return "submit"
        }
    }
    func HTMLButtonElement_set_type(_ n: HTMLNode, _ v: String) { n.setAttributeValue("type", v) }

    // MARK: select / option

    func HTMLSelectElement_type(_ n: HTMLNode) -> String { n.hasAttribute("multiple") ? "select-multiple" : "select-one" }
    func HTMLSelectElement_options(_ n: HTMLNode) -> JSValue { makeCollection(n, .selectOptions) }
    func HTMLSelectElement_selectedOptions(_ n: HTMLNode) -> JSValue { makeCollection(n, .selectedOptions) }
    func HTMLSelectElement_length(_ n: HTMLNode) throws(JSThrow) -> Int { selectOptions(n).count }
    func HTMLSelectElement_set_length(_ n: HTMLNode, _ v: Int) throws(JSThrow) {
        var opts = selectOptions(n)
        if v > 100_000 { return }
        while opts.count > v, let last = opts.popLast() { last.remove() }
        let doc = n.nodeDocument ?? document
        var k = opts.count
        while k < v { _ = try Node_appendChild(n, doc.makeElement("option", .html)); k += 1 }
    }
    func HTMLSelectElement_item(_ n: HTMLNode, _ i: Int) -> HTMLNode? {
        let o = selectOptions(n)
        return i >= 0 && i < o.count ? o[i] : nil
    }
    func HTMLSelectElement_namedItem(_ n: HTMLNode, _ name: String) -> JSValue {
        for o in selectOptions(n) where o.attribute("id") == name || o.attribute("name") == name { return wrapNode(o) }
        return .null
    }
    func HTMLSelectElement_add(_ n: HTMLNode, _ el: JSValue, _ before: JSValue) throws(JSThrow) {
        guard let e = nodeClass.unwrap(el), e.isHTML("option") || e.isHTML("optgroup") else {
            throw realm.throwTypeError("Failed to execute 'add' on 'HTMLSelectElement': The provided value is not an option or optgroup.")
        }
        var ref: HTMLNode? = nil
        if let b = nodeClass.unwrap(before) { ref = b }
        else if before.isNumber { ref = HTMLSelectElement_item(n, Int(before.numberValue)) }
        if let r = ref, let p = r.parent { _ = try Node_insertBefore(p, e, r) } else { _ = try Node_appendChild(n, e) }
    }
    func HTMLSelectElement_remove(_ n: HTMLNode, _ index: JSValue) {
        if index.isUndefined { n.remove(); return }
        let i = index.isNumber ? Int(index.numberValue) : 0
        HTMLSelectElement_item(n, i)?.remove()
    }
    func HTMLSelectElement_selectedIndex(_ n: HTMLNode) -> Int {
        let opts = selectOptions(n)
        for (i, o) in opts.enumerated() where optionSelected(o) { return i }
        return -1
    }
    func HTMLSelectElement_set_selectedIndex(_ n: HTMLNode, _ i: Int) {
        for (k, o) in selectOptions(n).enumerated() { control(o).selected = k == i }
        controlChanged(n)
    }
    func HTMLSelectElement_value(_ n: HTMLNode) -> String {
        for o in selectOptions(n) where optionSelected(o) { return HTMLOptionElement_value(o) }
        return ""
    }
    func HTMLSelectElement_set_value(_ n: HTMLNode, _ v: String) {
        var done = false
        for o in selectOptions(n) {
            let hit = !done && HTMLOptionElement_value(o) == v
            control(o).selected = hit
            if hit { done = true }
        }
        controlChanged(n)
    }

    func HTMLOptionElement_value(_ n: HTMLNode) -> String { n.attribute("value") ?? HTMLOptionElement_text(n) }
    func HTMLOptionElement_set_value(_ n: HTMLNode, _ v: String) { n.setAttributeValue("value", v) }
    func HTMLOptionElement_text(_ n: HTMLNode) -> String {
        var bytes: [UInt8] = []
        var stack: [HTMLNode] = [n]
        while let x = stack.popLast() {
            if x.kind == .text { bytes.append(contentsOf: x.data); continue }
            if x !== n && (x.isHTML("script") || x.namespace == .svg && x.name == "script") { continue }
            var i = x.children.count - 1
            while i >= 0 { stack.append(x.children[i]); i -= 1 }
        }
        return jsdomStripCollapse(String(decoding: bytes, as: UTF8.self))
    }
    func HTMLOptionElement_set_text(_ n: HTMLNode, _ v: String) { n.setTextContent(v) }
    func HTMLOptionElement_label(_ n: HTMLNode) -> String { n.attribute("label") ?? HTMLOptionElement_text(n) }
    func HTMLOptionElement_set_label(_ n: HTMLNode, _ v: String) { n.setAttributeValue("label", v) }
    func HTMLOptionElement_selected(_ n: HTMLNode) -> Bool { optionSelected(n) }
    func HTMLOptionElement_set_selected(_ n: HTMLNode, _ v: Bool) { setOptionSelected(n, v) }
    func HTMLOptionElement_index(_ n: HTMLNode) -> Int {
        guard let s = optionSelect(n) else { return 0 }
        return selectOptions(s).firstIndex { $0 === n } ?? 0
    }

    /// `new Option(text, value, defaultSelected, selected)`.
    func HTMLOptionElement_factory(_ args: JSArgs) throws(JSThrow) -> JSValue {
        let o = document.makeElement("option", .html)
        if !args[0].isUndefined { let t = try toStr(args[0]); if !t.isEmpty { _ = try? o.appendChild(document.createTextNode(t)) } }
        if !args[1].isUndefined { o.setAttributeValue("value", try toStr(args[1])) }
        if heap.toBoolean(args[2]) { o.setAttributeValue("selected", "") }
        if heap.toBoolean(args[3]) { control(o).selected = true }
        return wrapNode(o)
    }

    /// `new Image(width, height)`.
    func HTMLImageElement_factory(_ args: JSArgs) throws(JSThrow) -> JSValue {
        let i = document.makeElement("img", .html)
        if !args[0].isUndefined { i.setAttributeValue("width", String(try toUnsignedLong(args[0]))) }
        if !args[1].isUndefined { i.setAttributeValue("height", String(try toUnsignedLong(args[1]))) }
        return wrapNode(i)
    }

    // MARK: textarea

    func HTMLTextAreaElement_type(_ n: HTMLNode) -> String { "textarea" }
    func HTMLTextAreaElement_defaultValue(_ n: HTMLNode) -> String { Node_textContent(n) ?? "" }
    func HTMLTextAreaElement_set_defaultValue(_ n: HTMLNode, _ v: String) { n.setTextContent(v) }
    func HTMLTextAreaElement_value(_ n: HTMLNode) -> String {
        let raw = controls[ObjectIdentifier(n)]?.value ?? HTMLTextAreaElement_defaultValue(n)
        var out: [UInt8] = []
        var prevCR = false
        for b in raw.utf8 {
            if b == 0x0d { out.append(0x0a); prevCR = true; continue }
            if b == 0x0a && prevCR { prevCR = false; continue }
            prevCR = false
            out.append(b)
        }
        return String(decoding: out, as: UTF8.self)
    }
    func HTMLTextAreaElement_set_value(_ n: HTMLNode, _ v: String) {
        let c = control(n)
        c.value = v
        c.selectionStart = HTMLTextAreaElement_value(n).utf16.count
        c.selectionEnd = c.selectionStart
        controlChanged(n)
    }
    func HTMLTextAreaElement_textLength(_ n: HTMLNode) -> Int { HTMLTextAreaElement_value(n).utf16.count }

    // MARK: label, output, progress

    func HTMLLabelElement_control(_ n: HTMLNode) -> HTMLNode? {
        if let f = n.attribute("for") {
            let root = n.rootNode
            guard let t = descendantsMatching(root, { $0.attribute("id") == f }).first else { return nil }
            return jsdomIsLabelable(t) ? t : nil
        }
        return descendantsMatching(n) { jsdomIsLabelable($0) }.first
    }

    func HTMLOutputElement_value(_ n: HTMLNode) -> String { Node_textContent(n) ?? "" }
    func HTMLOutputElement_set_value(_ n: HTMLNode, _ v: String) { n.setTextContent(v) }

    func HTMLProgressElement_max(_ n: HTMLNode) -> Double {
        let m = n.attribute("max").flatMap { jsdomParseFloat($0) } ?? 1
        return m > 0 ? m : 1
    }
    func HTMLProgressElement_set_max(_ n: HTMLNode, _ v: Double) { if v > 0 { n.setAttributeValue("max", jsdomFormatNumber(v)) } }
    func HTMLProgressElement_value(_ n: HTMLNode) -> Double {
        let v = n.attribute("value").flatMap { jsdomParseFloat($0) } ?? 0
        return max(0, min(v, HTMLProgressElement_max(n)))
    }
    func HTMLProgressElement_set_value(_ n: HTMLNode, _ v: Double) { n.setAttributeValue("value", jsdomFormatNumber(v)) }

    // MARK: img

    func imageSize(_ n: HTMLNode) -> (Int, Int)? {
        guard let s = n.attribute("src"), !s.isEmpty else { return nil }
        return host.imageSize(resolveURL(s) ?? s)
    }
    func HTMLImageElement_width(_ n: HTMLNode) -> Int {
        if let r = layoutRect(n) { return Int(r.w.rounded()) }
        if let w = n.attribute("width").flatMap({ jsdomParseInteger($0) }), w >= 0 { return w }
        return imageSize(n)?.0 ?? 0
    }
    func HTMLImageElement_height(_ n: HTMLNode) -> Int {
        if let r = layoutRect(n) { return Int(r.h.rounded()) }
        if let h = n.attribute("height").flatMap({ jsdomParseInteger($0) }), h >= 0 { return h }
        return imageSize(n)?.1 ?? 0
    }
    func HTMLImageElement_set_width(_ n: HTMLNode, _ v: Int) { n.setAttributeValue("width", String(v)) }
    func HTMLImageElement_set_height(_ n: HTMLNode, _ v: Int) { n.setAttributeValue("height", String(v)) }
    func HTMLImageElement_naturalWidth(_ n: HTMLNode) -> Int { imageSize(n)?.0 ?? 0 }
    func HTMLImageElement_naturalHeight(_ n: HTMLNode) -> Int { imageSize(n)?.1 ?? 0 }
    func HTMLImageElement_complete(_ n: HTMLNode) -> Bool {
        guard let s = n.attribute("src"), !s.isEmpty else { return true }
        return imageSize(n) != nil || !host.imagePending(resolveURL(s) ?? s)
    }
    func HTMLImageElement_currentSrc(_ n: HTMLNode) -> String { reflectURL(n, "src") }
    func HTMLImageElement_decode(_ n: HTMLNode) throws(JSThrow) -> JSValue {
        try resolvedPromise(.undefined)
    }

    // MARK: template, slot, script, style, iframe, canvas, media, dialog

    func HTMLTemplateElement_content(_ n: HTMLNode) -> HTMLNode? { n.templateContents }

    func slotFlatten(_ options: JSValue) -> Bool {
        if options.isObject, case .value(let v) = heap.getProperty(options, heap.key("flatten")) { return heap.toBoolean(v) }
        return false
    }
    func HTMLSlotElement_assignedNodes(_ n: HTMLNode, _ o: JSValue) -> JSValue { nodeArray(n.assignedNodes(flatten: slotFlatten(o))) }
    func HTMLSlotElement_assignedElements(_ n: HTMLNode, _ o: JSValue) -> JSValue { nodeArray(n.assignedElements(flatten: slotFlatten(o))) }
    func HTMLSlotElement_assign(_ n: HTMLNode, _ items: [JSValue]) {
        var nodes: [HTMLNode] = []
        for v in items { if let x = nodeClass.unwrap(v), x.isSlottable { nodes.append(x) } }
        n.assign(nodes)
    }

    func HTMLScriptElement_text(_ n: HTMLNode) -> String {
        var bytes: [UInt8] = []
        for c in n.children where c.kind == .text { bytes.append(contentsOf: c.data) }
        return String(decoding: bytes, as: UTF8.self)
    }
    func HTMLScriptElement_set_text(_ n: HTMLNode, _ v: String) { n.setTextContent(v) }
    func HTMLStyleElement_sheet(_ n: HTMLNode) -> JSValue { .null }

    func HTMLIFrameElement_contentDocument(_ n: HTMLNode) -> JSValue { .null }
    func HTMLIFrameElement_contentWindow(_ n: HTMLNode) -> JSValue { .null }

    func HTMLCanvasElement_getContext(_ n: HTMLNode, _ type: String, _ rest: [JSValue]) -> JSValue { .null }
    func HTMLCanvasElement_toDataURL(_ n: HTMLNode, _ type: String, _ q: JSValue) throws(JSThrow) -> String { "data:," }

    func HTMLMediaElement_paused(_ n: HTMLNode) -> Bool { true }
    func HTMLMediaElement_play(_ n: HTMLNode) -> JSValue {
        (try? rejectedPromise(domException("NotSupportedError", "Media playback is not supported."))) ?? .undefined
    }
    func HTMLMediaElement_pause(_ n: HTMLNode) {}
    func HTMLMediaElement_load(_ n: HTMLNode) {}
    func HTMLMediaElement_canPlayType(_ n: HTMLNode, _ t: String) -> String { "" }

    func HTMLDialogElement_returnValue(_ n: HTMLNode) -> String { dialogReturn[ObjectIdentifier(n)] ?? "" }
    func HTMLDialogElement_set_returnValue(_ n: HTMLNode, _ v: String) { dialogReturn[ObjectIdentifier(n)] = v }
    func HTMLDialogElement_show(_ n: HTMLNode) throws(JSThrow) { if !n.hasAttribute("open") { n.setAttributeValue("open", "") } }
    func HTMLDialogElement_showModal(_ n: HTMLNode) throws(JSThrow) {
        if !n.isConnected { throw throwDOM("InvalidStateError", "The element is not in a document.") }
        if !n.hasAttribute("open") { n.setAttributeValue("open", "") }
    }
    func HTMLDialogElement_close(_ n: HTMLNode, _ v: String?) {
        guard n.hasAttribute("open") else { return }
        n.removeAttribute("open")
        if let r = v { dialogReturn[ObjectIdentifier(n)] = r }
        fire("close", at: .node(n))
    }

    // MARK: tables

    func HTMLTableElement_rows(_ n: HTMLNode) -> JSValue { makeCollection(n, .tableRows) }
    func HTMLTableElement_tBodies(_ n: HTMLNode) -> JSValue { makeCollection(n, .tBodies) }
    func HTMLTableElement_tHead(_ n: HTMLNode) -> HTMLNode? { n.children.first { $0.isHTML("thead") } }
    func HTMLTableElement_tFoot(_ n: HTMLNode) -> HTMLNode? { n.children.first { $0.isHTML("tfoot") } }
    func HTMLTableElement_caption(_ n: HTMLNode) -> HTMLNode? { n.children.first { $0.isHTML("caption") } }
    func HTMLTableElement_insertRow(_ n: HTMLNode, _ index: Int) throws(JSThrow) -> HTMLNode? {
        let rows = computeCollection(JSDOMHTMLCollection(n, .tableRows))
        if index < -1 || index > rows.count { throw throwDOM("IndexSizeError", "The index provided is outside the range of rows.") }
        let doc = n.nodeDocument ?? document
        let tr = doc.makeElement("tr", .html)
        if index == -1 || index == rows.count {
            if n.isHTML("table") {
                if let last = n.children.last(where: { $0.isHTML("tbody") }) { _ = try Node_appendChild(last, tr) }
                else if rows.isEmpty { let tb = doc.makeElement("tbody", .html); _ = try Node_appendChild(tb, tr); _ = try Node_appendChild(n, tb) }
                else if let p = rows.last?.parent { _ = try Node_appendChild(p, tr) }
            } else {
                _ = try Node_appendChild(n, tr)
            }
        } else if let p = rows[index].parent {
            _ = try Node_insertBefore(p, tr, rows[index])
        }
        return tr
    }
    func HTMLTableElement_deleteRow(_ n: HTMLNode, _ index: Int) throws(JSThrow) {
        let rows = computeCollection(JSDOMHTMLCollection(n, .tableRows))
        if index == -1 { rows.last?.remove(); return }
        if index < 0 || index >= rows.count { throw throwDOM("IndexSizeError", "The index provided is outside the range of rows.") }
        rows[index].remove()
    }
    func HTMLTableRowElement_cells(_ n: HTMLNode) -> JSValue { makeCollection(n, .rowCells) }
    func HTMLTableRowElement_rowIndex(_ n: HTMLNode) -> Int {
        var t = n.parent
        if let p = t, !p.isHTML("table") { t = p.parent }
        guard let table = t, table.isHTML("table") else { return -1 }
        return computeCollection(JSDOMHTMLCollection(table, .tableRows)).firstIndex { $0 === n } ?? -1
    }
    func HTMLTableRowElement_sectionRowIndex(_ n: HTMLNode) -> Int {
        guard let p = n.parent else { return -1 }
        return p.children.filter { $0.isHTML("tr") }.firstIndex { $0 === n } ?? -1
    }
    func HTMLTableRowElement_insertCell(_ n: HTMLNode, _ index: Int) throws(JSThrow) -> HTMLNode? {
        let cells = n.children.filter { $0.isHTML("td") || $0.isHTML("th") }
        if index < -1 || index > cells.count { throw throwDOM("IndexSizeError", "The index provided is outside the range of cells.") }
        let td = (n.nodeDocument ?? document).makeElement("td", .html)
        _ = try Node_insertBefore(n, td, index == -1 || index == cells.count ? nil : cells[index])
        return td
    }
    func HTMLTableRowElement_deleteCell(_ n: HTMLNode, _ index: Int) throws(JSThrow) {
        let cells = n.children.filter { $0.isHTML("td") || $0.isHTML("th") }
        if index == -1 { cells.last?.remove(); return }
        if index < 0 || index >= cells.count { throw throwDOM("IndexSizeError", "The index provided is outside the range of cells.") }
        cells[index].remove()
    }
    func HTMLTableCellElement_cellIndex(_ n: HTMLNode) -> Int {
        guard let p = n.parent, p.isHTML("tr") else { return -1 }
        return p.children.filter { $0.isHTML("td") || $0.isHTML("th") }.firstIndex { $0 === n } ?? -1
    }

    // MARK: Activation behavior

    /// Legacy-pre-activation behavior: checkboxes toggle (and radios check)
    /// before the click event is dispatched. Returns what to undo.
    func legacyPreActivation(_ n: HTMLNode) -> (HTMLNode, Bool, HTMLNode?)? {
        guard n.isHTML("input"), !isDisabled(n) else { return nil }
        let t = inputType(n)
        if t == "checkbox" {
            let old = inputChecked(n)
            control(n).checked = !old
            control(n).indeterminate = false
            controlChanged(n)
            return (n, old, nil)
        }
        if t == "radio" {
            let old = inputChecked(n)
            let prev = radioGroup(n).first { self.inputChecked($0) }
            setInputChecked(n, true)
            return (n, old, prev)
        }
        return nil
    }

    func legacyCanceledActivation(_ s: (HTMLNode, Bool, HTMLNode?)) {
        let (n, old, prev) = s
        control(n).checked = old
        if let p = prev { control(p).checked = true; controlChanged(p) }
        controlChanged(n)
    }

    func activationBehavior(_ n: HTMLNode, _ e: JSDOMEvent) throws(JSThrow) {
        if n.namespace != .html { return }
        switch n.name {
        case "a", "area":
            guard let href = n.attribute("href") else { return }
            let u = resolveURL(href) ?? href
            host.followHyperlink(n, u, n.attribute("target") ?? "")
        case "input":
            if isDisabled(n) { return }
            switch inputType(n) {
            case "checkbox", "radio":
                guard n.isConnected else { return }
                fire("input", at: .node(n), bubbles: true, iface: .Event)
                fire("change", at: .node(n), bubbles: true)
            case "submit", "image":
                if let f = formOwner(n), n.isConnected { submitForm(f, submitter: n) }
            case "reset":
                if let f = formOwner(n), n.isConnected { HTMLFormElement_reset(f) }
            default: break
            }
        case "button":
            if isDisabled(n) { return }
            guard let f = formOwner(n), n.isConnected else { return }
            switch HTMLButtonElement_type(n) {
            case "submit": submitForm(f, submitter: n)
            case "reset": HTMLFormElement_reset(f)
            default: break
            }
        case "label":
            // Forward the click to the labeled control (unless it was the target).
            guard let c = HTMLLabelElement_control(n) else { return }
            if case .node(let t)? = e.target, c.contains(t) || t === c { return }
            HTMLElement_click(c)
            if isFocusable(c) { setFocus(c) }
        case "summary":
            if let d = n.parent, d.isHTML("details"), d.children.first(where: { $0.isHTML("summary") }) === n {
                if d.hasAttribute("open") { d.removeAttribute("open") } else { d.setAttributeValue("open", "") }
                fire("toggle", at: .node(d))
            }
        default: break
        }
    }

    // MARK: Promises

    func resolvedPromise(_ v: JSValue) throws(JSThrow) -> JSValue {
        let ctor = realm.intrinsic(.promiseConstructor)
        let f = try realm.getV(ctor, heap.key("resolve"))
        return try realm.call(f, this: ctor, args: [v])
    }

    func rejectedPromise(_ v: JSValue) throws(JSThrow) -> JSValue {
        let ctor = realm.intrinsic(.promiseConstructor)
        let f = try realm.getV(ctor, heap.key("reject"))
        let d = heap.rootDepth
        _ = heap.root(v)
        defer { heap.popRoots(to: d) }
        return try realm.call(f, this: ctor, args: [v])
    }

    // MARK: form / select named and indexed access

    /// Exotic hook for <form> (form[0], form.fieldName) and <select>
    /// (select[0]) wrappers. Own properties and the prototype chain win.
    func makeFormExotic() -> JSExoticHandler {
        var h = JSExoticHandler()
        h.getOwnProperty = { [unowned(unsafe) self] (realm: JSRealm, o: JSValue, k: JSPropertyKey) throws(JSThrow) -> JSProperty? in
            guard let n = self.nodeClass.unwrap(o) else { return nil }
            if k.isIndex {
                let i = Int(k.index)
                let items = n.isHTML("form") ? self.computeCollection(JSDOMHTMLCollection(n, .formElements)) : self.selectOptions(n)
                return i < items.count ? .data(self.wrapNode(items[i]), [.enumerable, .configurable]) : nil
            }
            guard k.isString, n.isHTML("form"), realm.heap.getOwnProperty(o, k) == nil else { return nil }
            let name = realm.heap.swiftString(realm.heap.keyValue(k))
            if case .value = realm.heap.getProperty(realm.heap.getPrototypeOf(o), k) { return nil }
            if case .getter = realm.heap.getProperty(realm.heap.getPrototypeOf(o), k) { return nil }
            let items = self.computeCollection(JSDOMHTMLCollection(n, .formElements))
            for x in items where x.attribute("id") == name || x.attribute("name") == name {
                return .data(self.wrapNode(x), [.configurable])
            }
            return nil
        }
        h.get = { [unowned(unsafe) self] (realm: JSRealm, o: JSValue, k: JSPropertyKey, receiver: JSValue) throws(JSThrow) -> JSValue? in
            guard k.isIndex, let n = self.nodeClass.unwrap(o) else { return nil }
            let i = Int(k.index)
            let items = n.isHTML("form") ? self.computeCollection(JSDOMHTMLCollection(n, .formElements)) : self.selectOptions(n)
            return i < items.count ? self.wrapNode(items[i]) : nil
        }
        h.ownKeys = { [unowned(unsafe) self] (realm: JSRealm, o: JSValue) throws(JSThrow) -> [JSPropertyKey] in
            guard let n = self.nodeClass.unwrap(o) else { return [] }
            let c = n.isHTML("form") ? self.computeCollection(JSDOMHTMLCollection(n, .formElements)).count : self.selectOptions(n).count
            var keys: [JSPropertyKey] = []
            var i = 0
            while i < c && i < 100_000 { keys.append(.index(UInt32(i))); i += 1 }
            return keys
        }
        return h
    }
}

func jsdomIsLabelable(_ n: HTMLNode) -> Bool {
    guard n.kind == .element, n.namespace == .html else { return false }
    switch n.name {
    case "button", "meter", "output", "progress", "select", "textarea": return true
    case "input": return htmlLowerASCII(n.attribute("type") ?? "") != "hidden"
    default: return false
    }
}

func jsdomLooksLikeEmail(_ s: String) -> Bool {
    let b = Array(s.utf8)
    guard let at = b.firstIndex(of: 0x40), at > 0, at < b.count - 1 else { return false }
    for c in b where c == 0x20 || c == 0x0a { return false }
    return !b[(at + 1)...].contains(0x40)
}

/// HTML's "rules for parsing floating-point number values" (simplified).
func jsdomParseFloat(_ s: String) -> Double? {
    let b = Array(s.utf8)
    var i = 0
    var neg = false
    if i < b.count && b[i] == 0x2d { neg = true; i += 1 }
    var v = 0.0
    var any = false
    while i < b.count && b[i] >= 0x30 && b[i] <= 0x39 { v = v * 10 + Double(b[i] - 0x30); i += 1; any = true }
    if i < b.count && b[i] == 0x2e {
        i += 1
        var f = 0.1
        while i < b.count && b[i] >= 0x30 && b[i] <= 0x39 { v += Double(b[i] - 0x30) * f; f /= 10; i += 1; any = true }
    }
    if !any { return nil }
    if i < b.count && (b[i] == 0x65 || b[i] == 0x45) {
        i += 1
        var en = false
        if i < b.count && (b[i] == 0x2d || b[i] == 0x2b) { en = b[i] == 0x2d; i += 1 }
        var e = 0
        while i < b.count && b[i] >= 0x30 && b[i] <= 0x39 { if e < 400 { e = e * 10 + Int(b[i] - 0x30) }; i += 1 }
        var k = 0
        while k < e { v = en ? v / 10 : v * 10; k += 1 }
    }
    if i != b.count { return nil }
    return neg ? -v : v
}

/// A number as JavaScript would print it (for reflected numeric values).
func jsdomFormatNumber(_ d: Double) -> String {
    if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
    return String(decoding: jsNumberToString(d), as: UTF8.self)
}
