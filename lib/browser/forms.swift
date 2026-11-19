// Forms: the state the user changes (typed text, checked boxes, selected
// options) kept beside the DOM, and submission (HTML Standard "constructing
// the entry list", application/x-www-form-urlencoded, GET and POST).

/// What the user has done to the page's controls. `values` and `checked` are
/// handed to LayoutEngine.controlValues/controlChecked so the page draws them.
/// For a <select>, `values` holds the shown label and `selected` the index.
final class BrowserFormState {
    var values: [ObjectIdentifier: String] = [:]
    var checked: [ObjectIdentifier: Bool] = [:]
    var selected: [ObjectIdentifier: Int] = [:]

    init() {}

    func reset() { values = [:]; checked = [:]; selected = [:] }
}

struct BrowserOption {
    var label: String
    var value: String
    var disabled: Bool
    var selectedByDefault: Bool
    unowned(unsafe) var node: HTMLNode
}

private func browserLowerASCII(_ s: String) -> String {
    var out = ""
    for u in s.unicodeScalars {
        if u.value >= 0x41 && u.value <= 0x5a { out.unicodeScalars.append(Unicode.Scalar(u.value + 32)!) }
        else { out.unicodeScalars.append(u) }
    }
    return out
}

/// Collapse runs of whitespace and trim (option labels).
func browserCollapse(_ s: String) -> String {
    var out = ""
    var space = false
    for u in s.unicodeScalars {
        if u == " " || u == "\n" || u == "\t" || u == "\r" || u == "\u{0C}" {
            space = !out.isEmpty
        } else {
            if space { out += " "; space = false }
            out.unicodeScalars.append(u)
        }
    }
    return out
}

/// The lowercased `type` of an <input> ("text" when missing or unknown), or
/// of a <button> ("submit" by default).
func browserControlType(_ n: HTMLNode) -> String {
    let t = browserLowerASCII(n.attribute("type") ?? "")
    if n.name == "button" { return t == "button" || t == "reset" ? t : "submit" }
    if n.name != "input" { return n.name }
    switch t {
    case "hidden", "text", "search", "tel", "url", "email", "password", "date", "month", "week", "time",
         "datetime-local", "number", "range", "color", "checkbox", "radio", "file", "submit", "image", "reset", "button":
        return t
    default:
        return "text"
    }
}

/// Inputs edited as a line of text.
func browserIsTextControl(_ n: HTMLNode) -> Bool {
    if n.name == "textarea" { return true }
    guard n.name == "input" else { return false }
    switch browserControlType(n) {
    case "text", "search", "tel", "url", "email", "password", "date", "month", "week", "time", "datetime-local",
         "number": return true
    default: return false
    }
}

/// Buttons that submit their form.
func browserIsSubmitButton(_ n: HTMLNode) -> Bool {
    if n.name == "button" { return browserControlType(n) == "submit" }
    if n.name == "input" { let t = browserControlType(n); return t == "submit" || t == "image" }
    return false
}

private func browserRoot(_ n: HTMLNode) -> HTMLNode {
    var r = n
    var k = 0
    while let p = r.parent, k < 100_000 { r = p; k += 1 }
    return r
}

/// The form a control belongs to: its `form` attribute's element, else the
/// nearest <form> ancestor.
func browserFormOwner(_ n: HTMLNode) -> HTMLNode? {
    if let id = n.attribute("form") {
        if let f = browserRoot(n).getElementById(id), f.name == "form" { return f }
        return nil
    }
    var p = n.parent
    var k = 0
    while let q = p, k < 100_000 {
        if q.kind == .element && q.name == "form" { return q }
        p = q.parent
        k += 1
    }
    return nil
}

/// Disabled itself, or inside a disabled <fieldset> (not in its first legend).
func browserIsDisabled(_ n: HTMLNode) -> Bool {
    if n.hasAttribute("disabled") { return true }
    var p = n.parent
    var k = 0
    while let q = p, k < 100_000 {
        if q.kind == .element && q.name == "fieldset" && q.hasAttribute("disabled") { return true }
        p = q.parent
        k += 1
    }
    return false
}

/// The options of a <select> (directly or in an <optgroup>), in order.
func browserSelectOptions(_ select: HTMLNode) -> [BrowserOption] {
    var out: [BrowserOption] = []
    func add(_ o: HTMLNode, groupDisabled: Bool) {
        let label = o.attribute("label") ?? browserCollapse(o.textContent)
        out.append(BrowserOption(label: label, value: o.attribute("value") ?? browserCollapse(o.textContent),
                                 disabled: groupDisabled || o.hasAttribute("disabled"),
                                 selectedByDefault: o.hasAttribute("selected"), node: o))
    }
    for c in select.children where c.kind == .element {
        if c.name == "option" { add(c, groupDisabled: false) }
        else if c.name == "optgroup" {
            for o in c.children where o.kind == .element && o.name == "option" { add(o, groupDisabled: c.hasAttribute("disabled")) }
        }
        if out.count >= 10_000 { break }
    }
    return out
}

/// The selected option index of a single <select> (-1: none).
func browserSelectedIndex(_ select: HTMLNode, _ state: BrowserFormState) -> Int {
    let opts = browserSelectOptions(select)
    if let i = state.selected[ObjectIdentifier(select)], i >= 0, i < opts.count { return i }
    var last = -1
    for (i, o) in opts.enumerated() where o.selectedByDefault { last = i }
    if last >= 0 { return last }
    for (i, o) in opts.enumerated() where !o.disabled { return i }
    return opts.isEmpty ? -1 : 0
}

/// Choose option `i` of a <select>.
func browserSelectOption(_ select: HTMLNode, _ i: Int, _ state: BrowserFormState) {
    let opts = browserSelectOptions(select)
    guard i >= 0, i < opts.count else { return }
    state.selected[ObjectIdentifier(select)] = i
    state.values[ObjectIdentifier(select)] = opts[i].label
}

/// The current text of a text control.
func browserControlValue(_ n: HTMLNode, _ state: BrowserFormState) -> String {
    if let v = state.values[ObjectIdentifier(n)] { return v }
    if n.name == "textarea" {
        var t = n.textContent
        // The parser drops a leading newline already; keep the rest as is.
        if t.utf8.first == 0x0a { t = String(t.dropFirst()) }
        return t
    }
    return n.attribute("value") ?? ""
}

func browserIsChecked(_ n: HTMLNode, _ state: BrowserFormState) -> Bool {
    state.checked[ObjectIdentifier(n)] ?? n.hasAttribute("checked")
}

/// Radios in the same group as `radio` (same name, same form owner).
func browserRadioGroup(_ radio: HTMLNode) -> [HTMLNode] {
    guard let name = radio.attribute("name"), !name.isEmpty else { return [radio] }
    let owner = browserFormOwner(radio)
    return browserRoot(radio).elements { e in
        e.name == "input" && browserControlType(e) == "radio" && e.attribute("name") == name
            && browserFormOwner(e) === owner
    }
}

/// A click on a checkbox or radio. Returns true if anything changed.
@discardableResult
func browserToggle(_ n: HTMLNode, _ state: BrowserFormState) -> Bool {
    guard n.name == "input", !browserIsDisabled(n) else { return false }
    switch browserControlType(n) {
    case "checkbox":
        state.checked[ObjectIdentifier(n)] = !browserIsChecked(n, state)
        return true
    case "radio":
        if browserIsChecked(n, state) { return false }
        for r in browserRadioGroup(n) { state.checked[ObjectIdentifier(r)] = false }
        state.checked[ObjectIdentifier(n)] = true
        return true
    default:
        return false
    }
}

/// The control a <label> is for (its `for` element, else the first control inside it).
func browserLabelTarget(_ label: HTMLNode) -> HTMLNode? {
    if let f = label.attribute("for") {
        if let t = browserRoot(label).getElementById(f), ["input", "select", "textarea", "button"].contains(t.name) { return t }
        return nil
    }
    return label.firstElement { $0 !== label && ($0.name == "input" || $0.name == "select" || $0.name == "textarea" || $0.name == "button") }
}

/// The nearest <label> around `n` (or `n` itself).
func browserEnclosingLabel(_ n: HTMLNode) -> HTMLNode? {
    var p: HTMLNode? = n
    var k = 0
    while let q = p, k < 4096 {
        if q.kind == .element && q.name == "label" { return q }
        p = q.parent
        k += 1
    }
    return nil
}

/// Controls owned by `form`, in tree order.
func browserFormControls(_ form: HTMLNode) -> [HTMLNode] {
    let root = browserRoot(form)
    let formID = form.attribute("id")
    return root.elements { e in
        guard e.name == "input" || e.name == "select" || e.name == "textarea" || e.name == "button" else { return false }
        if let fid = formID, e.attribute("form") == fid { return true }
        return browserFormOwner(e) === form
    }
}

/// Reset a form's controls to their defaults.
func browserResetForm(_ form: HTMLNode, _ state: BrowserFormState) {
    for c in browserFormControls(form) {
        let id = ObjectIdentifier(c)
        state.values[id] = nil
        state.checked[id] = nil
        state.selected[id] = nil
    }
}

/// The form's entry list (name, value) for a submission by `submitter`.
func browserFormEntries(_ form: HTMLNode, submitter: HTMLNode?, _ state: BrowserFormState) -> [URLFormPair] {
    var out: [URLFormPair] = []
    for c in browserFormControls(form) {
        if browserIsDisabled(c) { continue }
        let type = browserControlType(c)
        if c.name == "button" || type == "submit" || type == "image" || type == "reset" || type == "button" {
            guard c === submitter, type != "reset", type != "button" else { continue }
            let name = c.attribute("name") ?? ""
            if type == "image" {
                let p = name.isEmpty ? "" : name + "."
                out.append(URLFormPair(p + "x", "0"))
                out.append(URLFormPair(p + "y", "0"))
                continue
            }
            if !name.isEmpty { out.append(URLFormPair(name, c.attribute("value") ?? (c.name == "button" ? "" : "Submit"))) }
            continue
        }
        guard let name = c.attribute("name"), !name.isEmpty else { continue }
        switch type {
        case "checkbox", "radio":
            if browserIsChecked(c, state) { out.append(URLFormPair(name, c.attribute("value") ?? "on")) }
        case "file":
            out.append(URLFormPair(name, ""))
        case "select":
            let opts = browserSelectOptions(c)
            if c.hasAttribute("multiple") {
                for o in opts where o.selectedByDefault && !o.disabled { out.append(URLFormPair(name, o.value)) }
            } else {
                let i = browserSelectedIndex(c, state)
                if i >= 0 && i < opts.count && !opts[i].disabled { out.append(URLFormPair(name, opts[i].value)) }
            }
        case "textarea":
            // Newlines are normalized to CRLF.
            var v = ""
            var prevCR = false
            for u in browserControlValue(c, state).unicodeScalars {
                if u == "\n" && !prevCR { v += "\r\n" } else { v.unicodeScalars.append(u) }
                prevCR = u == "\r"
            }
            out.append(URLFormPair(name, v))
        default:
            out.append(URLFormPair(name, browserControlValue(c, state)))
        }
        if out.count >= 10_000 { break }
    }
    return out
}

/// The first submit button of a form (Enter in a field "clicks" it).
func browserDefaultButton(_ form: HTMLNode) -> HTMLNode? {
    for c in browserFormControls(form) where browserIsSubmitButton(c) { return c }
    return nil
}

/// The request a submission makes, or nil (no usable action URL).
/// `documentURL` is the page's URL, `base` its base URL.
func browserFormSubmission(_ form: HTMLNode, submitter: HTMLNode?, _ state: BrowserFormState,
                           documentURL: URLRecord, base: URLRecord) -> BrowserRequest? {
    let action = submitter?.attribute("formaction") ?? form.attribute("action") ?? ""
    var url: URLRecord
    if action.isEmpty { url = documentURL } else {
        guard let u = base.resolve(action) else { return nil }
        url = u
    }
    let method = browserLowerASCII(submitter?.attribute("formmethod") ?? form.attribute("method") ?? "get")
    let body = urlFormEncode(browserFormEntries(form, submitter: submitter, state))
    var req = BrowserRequest(url: url)
    if method == "post" {
        req.method = "POST"
        req.body = body
        req.contentType = "application/x-www-form-urlencoded"
    } else {
        req.url.query = body
    }
    return req
}
