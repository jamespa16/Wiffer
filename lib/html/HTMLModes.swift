// The insertion modes (WHATWG "The rules for parsing tokens in HTML
// content"), as extensions of HTMLTreeBuilder.

extension HTMLTreeBuilder {
    // ------------------------------------------------------------ tokens

    func modeChar(_ c: UInt32) {
        let ws = htmlIsSpace(c)
        switch mode {
        case .initial:
            if ws { return }
            quirks = true
            mode = .beforeHtml
            modeChar(c)
        case .beforeHtml:
            if ws { return }
            createHTMLRoot([])
            modeChar(c)
        case .beforeHead:
            if ws { return }
            headElement = insertHTMLNamed(.head, "head")
            mode = .inHead
            modeChar(c)
        case .inHead:
            if ws { insertCharacter(c) } else { pop(); mode = .afterHead; modeChar(c) }
        case .inHeadNoscript:
            if ws { insertCharacter(c) } else { pop(); mode = .inHead; modeChar(c) }
        case .afterHead:
            if ws { insertCharacter(c) } else {
                _ = insertHTMLNamed(.body, "body")
                mode = .inBody
                modeChar(c)
            }
        case .inBody, .inCaption, .inCell:
            bodyChar(c)
        case .text:
            insertCharacter(c)
        case .inTable, .inTableBody, .inRow:
            tableChar(c)
        case .inTableText:
            if c == 0 { return }
            tableText.append(c)
            if !ws { tableTextHasNonSpace = true }
        case .inColumnGroup:
            if ws { insertCharacter(c) }
            else if currentIs(.colgroup) { pop(); mode = .inTable; modeChar(c) }
        case .inSelect, .inSelectInTable:
            bodyChar(c)
        case .afterBody, .afterAfterBody:
            if ws { bodyChar(c) } else { mode = .inBody; modeChar(c) }
        case .inFrameset, .afterFrameset:
            if ws { insertCharacter(c) }
        case .afterAfterFrameset:
            if ws { bodyChar(c) }
        case .inTemplate:
            bodyChar(c)
        }
    }

    func bodyChar(_ c: UInt32) {
        if c == 0 { return }
        reconstructFormatting()
        insertCharacter(c)
        if !htmlIsSpace(c) { framesetOK = false }
    }

    func tableChar(_ c: UInt32) {
        if let n = open.last, n.namespace == .html {
            switch n.tag {
            case .table, .tbody, .tfoot, .thead, .tr, .template:
                tableText.removeAll(keepingCapacity: true)
                tableTextHasNonSpace = false
                originalMode = mode
                mode = .inTableText
                modeChar(c)
                return
            default: break
            }
        }
        fosterParenting = true
        bodyChar(c)
        fosterParenting = false
    }

    func flushTableText() {
        mode = originalMode
        if tableTextHasNonSpace {
            fosterParenting = true
            for c in tableText { bodyChar(c) }
            fosterParenting = false
        } else {
            for c in tableText { insertCharacter(c) }
        }
        tableText.removeAll(keepingCapacity: true)
    }

    func modeComment(_ data: [UInt8]) {
        if mode == .inTableText { flushTableText() }
        switch mode {
        case .initial, .beforeHtml, .afterAfterBody, .afterAfterFrameset:
            doc.parserAppend(newNode(.comment, data: data))
        case .afterBody:
            if let html = open.first { html.parserAppend(newNode(.comment, data: data)) }
            else { doc.parserAppend(newNode(.comment, data: data)) }
        default:
            insertComment(data)
        }
    }

    func modeEOF() {
        if mode == .inTableText { flushTableText() }
        while true {
            switch mode {
            case .initial:
                quirks = true
                mode = .beforeHtml
            case .beforeHtml:
                createHTMLRoot([])
            case .beforeHead:
                headElement = insertHTMLNamed(.head, "head")
                mode = .inHead
            case .inHead, .inHeadNoscript:
                pop()
                mode = mode == .inHead ? .afterHead : .inHead
            case .afterHead:
                _ = insertHTMLNamed(.body, "body")
                mode = .inBody
            case .text:
                pop()
                mode = originalMode
            case .inBody, .inTable, .inCaption, .inColumnGroup, .inTableBody, .inRow, .inCell,
                 .inSelect, .inSelectInTable, .inTemplate:
                // "in body" EOF defers to "in template" while templates are open.
                if templateModes.isEmpty || !templateOnStack { return }
                popUntil(.template)
                clearFormattingToMarker()
                templateModes.removeLast()
                resetInsertionMode()
            default:
                return
            }
        }
    }

    func createHTMLRoot(_ attrs: [HTMLAttribute]) {
        let n = newNode(.element, name: "html", tag: .html, attrs: attrs)
        doc.parserAppend(n)
        open = [n]
        mode = .beforeHead
    }

    // ------------------------------------------------------- start tags

    func modeStart(_ t: HTMLStartToken) {
        if mode == .inTableText { flushTableText() }
        switch mode {
        case .initial:
            quirks = true
            mode = .beforeHtml
            modeStart(t)
        case .beforeHtml:
            if t.tag == .html { createHTMLRoot(t.attrs) } else { createHTMLRoot([]); modeStart(t) }
        case .beforeHead:
            switch t.tag {
            case .html: bodyStart(t)
            case .head: headElement = insertHTML(t); mode = .inHead
            default:
                headElement = insertHTMLNamed(.head, "head")
                mode = .inHead
                modeStart(t)
            }
        case .inHead:
            headStart(t)
        case .inHeadNoscript:
            switch t.tag {
            case .html: bodyStart(t)
            case .basefont, .bgsound, .link, .meta, .noframes, .style: headStart(t)
            case .head, .noscript: break
            default: pop(); mode = .inHead; modeStart(t)
            }
        case .afterHead:
            switch t.tag {
            case .html: bodyStart(t)
            case .body: insertHTML(t); framesetOK = false; mode = .inBody
            case .frameset: insertHTML(t); mode = .inFrameset
            case .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template, .title:
                if let h = headElement {
                    open.append(h)
                    headStart(t)
                    removeFromOpen(h)
                } else { headStart(t) }
            case .head: break
            default:
                _ = insertHTMLNamed(.body, "body")
                mode = .inBody
                modeStart(t)
            }
        case .inBody:
            bodyStart(t)
        case .text:
            break
        case .inTable:
            tableStart(t)
        case .inTableText:
            break
        case .inCaption:
            switch t.tag {
            case .caption, .col, .colgroup, .tbody, .td, .tfoot, .th, .thead, .tr:
                if closeCaption() { modeStart(t) }
            default: bodyStart(t)
            }
        case .inColumnGroup:
            switch t.tag {
            case .html: bodyStart(t)
            case .col: insertVoid(t)
            case .template: headStart(t)
            default:
                if currentIs(.colgroup) { pop(); mode = .inTable; modeStart(t) }
            }
        case .inTableBody:
            switch t.tag {
            case .tr:
                clearToContext(.tbody); insertHTML(t); mode = .inRow
            case .th, .td:
                clearToContext(.tbody)
                _ = insertHTMLNamed(.tr, "tr")
                mode = .inRow
                modeStart(t)
            case .caption, .col, .colgroup, .tbody, .tfoot, .thead:
                if closeTableBody() { modeStart(t) }
            default: tableStart(t)
            }
        case .inRow:
            switch t.tag {
            case .th, .td:
                clearToContext(.tr); insertHTML(t); mode = .inCell; pushMarker()
            case .caption, .col, .colgroup, .tbody, .tfoot, .thead, .tr:
                if closeRow() { modeStart(t) }
            default: tableStart(t)
            }
        case .inCell:
            switch t.tag {
            case .caption, .col, .colgroup, .tbody, .td, .tfoot, .th, .thead, .tr:
                if closeCell() { modeStart(t) }
            default: bodyStart(t)
            }
        case .inSelect, .inSelectInTable:
            selectStart(t)
        case .afterBody, .afterAfterBody:
            if t.tag == .html { bodyStart(t) } else { mode = .inBody; modeStart(t) }
        case .inFrameset:
            switch t.tag {
            case .html: bodyStart(t)
            case .frameset: insertHTML(t)
            case .frame: insertVoid(t)
            case .noframes: headStart(t)
            default: break
            }
        case .afterFrameset, .afterAfterFrameset:
            switch t.tag {
            case .html: bodyStart(t)
            case .noframes: headStart(t)
            default: break
            }
        case .inTemplate:
            templateStart(t)
        }
    }

    func templateStart(_ t: HTMLStartToken) {
        switch t.tag {
        case .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template, .title:
            headStart(t)
        case .caption, .colgroup, .tbody, .tfoot, .thead:
            switchTemplateMode(.inTable); modeStart(t)
        case .col:
            switchTemplateMode(.inColumnGroup); modeStart(t)
        case .tr:
            switchTemplateMode(.inTableBody); modeStart(t)
        case .td, .th:
            switchTemplateMode(.inRow); modeStart(t)
        default:
            switchTemplateMode(.inBody); modeStart(t)
        }
    }

    func switchTemplateMode(_ m: HTMLMode) {
        if !templateModes.isEmpty { templateModes.removeLast() }
        templateModes.append(m)
        mode = m
    }

    /// An end tag "template" (in head rules, reached from most modes).
    func endTemplate() {
        if !templateOnStack { return }
        generateAllImpliedEndTags()
        popUntil(.template)
        clearFormattingToMarker()
        if !templateModes.isEmpty { templateModes.removeLast() }
        resetInsertionMode()
    }

    func genericRaw(_ t: HTMLStartToken, rcdata: Bool) {
        insertHTML(t)
        tokenizer.state = rcdata ? .rcdata : .rawtext
        originalMode = mode
        mode = .text
    }

    func headStart(_ t: HTMLStartToken) {
        switch t.tag {
        case .html: bodyStart(t)
        case .base, .basefont, .bgsound, .link, .meta: insertVoid(t)
        case .title: genericRaw(t, rcdata: true)
        case .noscript:
            insertHTML(t)
            mode = .inHeadNoscript
        case .noframes, .style: genericRaw(t, rcdata: false)
        case .template:
            insertHTML(t)
            pushMarker()
            framesetOK = false
            mode = .inTemplate
            templateModes.append(.inTemplate)
        case .script:
            insertHTML(t)
            tokenizer.state = .scriptData
            originalMode = mode
            mode = .text
        case .head: break
        default:
            pop()
            mode = .afterHead
            modeStart(t)
        }
    }

    /// Clear the stack back to a table/table body/table row context.
    func clearToContext(_ kind: HTMLTag) {
        while let n = open.last {
            if n.namespace == .html {
                switch kind {
                case .table: if n.tag == .table || n.tag == .template || n.tag == .html { return }
                case .tbody: if n.tag == .tbody || n.tag == .tfoot || n.tag == .thead || n.tag == .template || n.tag == .html { return }
                default: if n.tag == .tr || n.tag == .template || n.tag == .html { return }
                }
            }
            open.removeLast()
        }
    }

    func closeCaption() -> Bool {
        if !hasInScope(.caption, .table) { return false }
        generateImpliedEndTags()
        popUntil(.caption)
        clearFormattingToMarker()
        mode = .inTable
        return true
    }
    func closeCell() -> Bool {
        guard hasInScope(.td, .table) || hasInScope(.th, .table) else { return false }
        generateImpliedEndTags()
        while let n = open.last {
            open.removeLast()
            if isHTML(n, .td) || isHTML(n, .th) { break }
        }
        clearFormattingToMarker()
        mode = .inRow
        return true
    }
    func closeRow() -> Bool {
        if !hasInScope(.tr, .table) { return false }
        clearToContext(.tr)
        pop()
        mode = .inTableBody
        return true
    }
    func closeTableBody() -> Bool {
        guard hasInScope(.tbody, .table) || hasInScope(.thead, .table) || hasInScope(.tfoot, .table) else { return false }
        clearToContext(.tbody)
        pop()
        mode = .inTable
        return true
    }

    func tableStart(_ t: HTMLStartToken) {
        switch t.tag {
        case .caption:
            clearToContext(.table); pushMarker(); insertHTML(t); mode = .inCaption
        case .colgroup:
            clearToContext(.table); insertHTML(t); mode = .inColumnGroup
        case .col:
            clearToContext(.table)
            _ = insertHTMLNamed(.colgroup, "colgroup")
            mode = .inColumnGroup
            modeStart(t)
        case .tbody, .tfoot, .thead:
            clearToContext(.table); insertHTML(t); mode = .inTableBody
        case .td, .th, .tr:
            clearToContext(.table)
            _ = insertHTMLNamed(.tbody, "tbody")
            mode = .inTableBody
            modeStart(t)
        case .table:
            if !hasInScope(.table, .table) { return }
            popUntil(.table)
            resetInsertionMode()
            modeStart(t)
        case .style, .script, .template:
            headStart(t)
        case .input:
            var hidden = false
            for a in t.attrs where a.name == "type" { hidden = htmlLowerASCII(a.value) == "hidden" }
            if hidden { insertVoid(t) } else { tableAnythingElseStart(t) }
        case .form:
            if formElement != nil || templateOnStack { return }
            formElement = insertElement(name: t.name, tag: t.tag, attrs: t.attrs, push: false)
        default:
            tableAnythingElseStart(t)
        }
    }

    func tableAnythingElseStart(_ t: HTMLStartToken) {
        fosterParenting = true
        bodyStart(t)
        fosterParenting = false
    }

    func selectStart(_ t: HTMLStartToken) {
        switch t.tag {
        case .html: bodyStart(t)
        case .option:
            if currentIs(.option) { pop() }
            reconstructFormatting()
            insertHTML(t)
        case .optgroup:
            if currentIs(.option) { pop() }
            if currentIs(.optgroup) { pop() }
            reconstructFormatting()
            insertHTML(t)
        case .hr:
            if currentIs(.option) { pop() }
            if currentIs(.optgroup) { pop() }
            insertVoid(t)
        case .select:
            if indexOfSelect() != nil { popUntil(.select); resetInsertionMode() }
        case .input, .textarea:
            if !hasInScope(.select, .select) { return }
            popUntil(.select)
            resetInsertionMode()
            modeStart(t)
        case .script, .template: headStart(t)
        case .caption, .table, .tbody, .tfoot, .thead, .tr, .td, .th:
            if mode == .inSelectInTable {
                popUntil(.select)
                resetInsertionMode()
                modeStart(t)
            } else { bodyStart(t) }
        default: bodyStart(t)
        }
    }

    func indexOfSelect() -> Int? {
        var i = open.count - 1
        while i >= 0 { if isHTML(open[i], .select) { return i }; i -= 1 }
        return nil
    }

    func addMissingAttrs(_ node: HTMLNode, _ attrs: [HTMLAttribute]) {
        for a in attrs {
            var have = false
            for b in node.attributes where b.name == a.name { have = true; break }
            if !have { node.attributes.append(a) }
        }
    }

    func bodyStart(_ t: HTMLStartToken) {
        switch t.tag {
        case .html:
            if templateOnStack { return }
            if let h = open.first { addMissingAttrs(h, t.attrs) }
        case .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template, .title:
            headStart(t)
        case .body:
            if open.count >= 2 && isHTML(open[1], .body) && !templateOnStack {
                framesetOK = false
                addMissingAttrs(open[1], t.attrs)
            }
        case .frameset:
            if open.count < 2 || !isHTML(open[1], .body) || !framesetOK { return }
            open[1].parserDetach()
            while open.count > 1 { open.removeLast() }
            insertHTML(t)
            mode = .inFrameset
        case .address, .article, .aside, .blockquote, .center, .details, .dialog, .dir, .div, .dl,
             .fieldset, .figcaption, .figure, .footer, .header, .hgroup, .main, .menu, .nav, .ol,
             .p, .search, .section, .summary, .ul:
            closePIfInButtonScope()
            insertHTML(t)
        case .h1, .h2, .h3, .h4, .h5, .h6:
            closePIfInButtonScope()
            if let n = open.last, isHeading(n) { pop() }
            insertHTML(t)
        case .pre, .listing:
            closePIfInButtonScope()
            insertHTML(t)
            ignoreLF = true
            framesetOK = false
        case .form:
            let tpl = templateOnStack
            if formElement != nil && !tpl { return }
            closePIfInButtonScope()
            let f = insertHTML(t)
            if !tpl { formElement = f }
        case .li:
            framesetOK = false
            var i = open.count - 1
            while i >= 0 {
                let n = open[i]
                if isHTML(n, .li) { generateImpliedEndTags(except: .li); popUntil(.li); break }
                if isSpecial(n) && !(isHTML(n, .address) || isHTML(n, .div) || isHTML(n, .p)) { break }
                i -= 1
            }
            closePIfInButtonScope()
            insertHTML(t)
        case .dd, .dt:
            framesetOK = false
            var i = open.count - 1
            while i >= 0 {
                let n = open[i]
                if isHTML(n, .dd) || isHTML(n, .dt) {
                    generateImpliedEndTags(except: n.tag)
                    popUntil(n.tag)
                    break
                }
                if isSpecial(n) && !(isHTML(n, .address) || isHTML(n, .div) || isHTML(n, .p)) { break }
                i -= 1
            }
            closePIfInButtonScope()
            insertHTML(t)
        case .plaintext:
            closePIfInButtonScope()
            insertHTML(t)
            tokenizer.state = .plaintext
        case .button:
            if hasInScope(.button) { generateImpliedEndTags(); popUntil(.button) }
            reconstructFormatting()
            insertHTML(t)
            framesetOK = false
        case .a:
            var i = afe.count - 1
            while i >= 0 {
                guard let e = afe[i] else { break }
                if isHTML(e, .a) {
                    adoptionAgency(.a, "a")
                    if let ai = afeIndex(e) { afe.remove(at: ai) }
                    removeFromOpen(e)
                    break
                }
                i -= 1
            }
            reconstructFormatting()
            pushFormatting(insertHTML(t))
        case .b, .big, .code, .em, .font, .i, .s, .small, .strike, .strong, .tt, .u:
            reconstructFormatting()
            pushFormatting(insertHTML(t))
        case .nobr:
            reconstructFormatting()
            if hasInScope(.nobr) { adoptionAgency(.nobr, "nobr"); reconstructFormatting() }
            pushFormatting(insertHTML(t))
        case .applet, .marquee, .object:
            reconstructFormatting()
            insertHTML(t)
            pushMarker()
            framesetOK = false
        case .table:
            if !quirks { closePIfInButtonScope() }
            insertHTML(t)
            framesetOK = false
            mode = .inTable
        case .area, .br, .embed, .img, .keygen, .wbr:
            reconstructFormatting()
            insertVoid(t)
            framesetOK = false
        case .input:
            reconstructFormatting()
            insertVoid(t)
            var hidden = false
            for a in t.attrs where a.name == "type" { hidden = htmlLowerASCII(a.value) == "hidden" }
            if !hidden { framesetOK = false }
        case .param, .source, .track:
            insertVoid(t)
        case .hr:
            closePIfInButtonScope()
            insertVoid(t)
            framesetOK = false
        case .image:
            var u = t
            u.name = "img"
            u.tag = .img
            bodyStart(u)
        case .textarea:
            insertHTML(t)
            ignoreLF = true
            tokenizer.state = .rcdata
            originalMode = mode
            framesetOK = false
            mode = .text
        case .xmp:
            closePIfInButtonScope()
            reconstructFormatting()
            framesetOK = false
            genericRaw(t, rcdata: false)
        case .iframe:
            framesetOK = false
            genericRaw(t, rcdata: false)
        case .noembed:
            genericRaw(t, rcdata: false)
        case .select:
            reconstructFormatting()
            insertHTML(t)
            framesetOK = false
            switch mode {
            case .inTable, .inCaption, .inTableBody, .inRow, .inCell: mode = .inSelectInTable
            default: mode = .inSelect
            }
        case .optgroup, .option:
            if currentIs(.option) { pop() }
            reconstructFormatting()
            insertHTML(t)
        case .rb, .rtc:
            if hasInScope(.ruby) { generateImpliedEndTags() }
            insertHTML(t)
        case .rp, .rt:
            if hasInScope(.ruby) { generateImpliedEndTags(except: .rtc) }
            insertHTML(t)
        case .math:
            reconstructFormatting()
            insertForeign(t, .mathml)
        case .svg:
            reconstructFormatting()
            insertForeign(t, .svg)
        case .caption, .col, .colgroup, .frame, .head, .tbody, .td, .tfoot, .th, .thead, .tr:
            break
        default:
            reconstructFormatting()
            insertHTML(t)
        }
    }

    // --------------------------------------------------------- end tags

    func modeEnd(_ t: HTMLEndToken) {
        if mode == .inTableText { flushTableText() }
        switch mode {
        case .initial:
            quirks = true
            mode = .beforeHtml
            modeEnd(t)
        case .beforeHtml:
            switch t.tag {
            case .head, .body, .html, .br: createHTMLRoot([]); modeEnd(t)
            default: break
            }
        case .beforeHead:
            switch t.tag {
            case .head, .body, .html, .br:
                headElement = insertHTMLNamed(.head, "head")
                mode = .inHead
                modeEnd(t)
            default: break
            }
        case .inHead:
            switch t.tag {
            case .head: pop(); mode = .afterHead
            case .body, .html, .br: pop(); mode = .afterHead; modeEnd(t)
            case .template: endTemplate()
            default: break
            }
        case .inHeadNoscript:
            switch t.tag {
            case .noscript: pop(); mode = .inHead
            case .br: pop(); mode = .inHead; modeEnd(t)
            default: break
            }
        case .afterHead:
            switch t.tag {
            case .body, .html, .br:
                _ = insertHTMLNamed(.body, "body")
                mode = .inBody
                modeEnd(t)
            case .template: endTemplate()
            default: break
            }
        case .inBody:
            bodyEnd(t)
        case .text:
            pop()
            mode = originalMode
        case .inTable:
            tableEnd(t)
        case .inTableText:
            break
        case .inCaption:
            switch t.tag {
            case .caption: _ = closeCaption()
            case .table: if closeCaption() { modeEnd(t) }
            case .body, .col, .colgroup, .html, .tbody, .td, .tfoot, .th, .thead, .tr: break
            default: bodyEnd(t)
            }
        case .inColumnGroup:
            switch t.tag {
            case .colgroup: if currentIs(.colgroup) { pop(); mode = .inTable }
            case .col: break
            case .template: endTemplate()
            default:
                if currentIs(.colgroup) { pop(); mode = .inTable; modeEnd(t) }
            }
        case .inTableBody:
            switch t.tag {
            case .tbody, .tfoot, .thead:
                if hasInScope(t.tag, .table) { clearToContext(.tbody); pop(); mode = .inTable }
            case .table:
                if closeTableBody() { modeEnd(t) }
            case .body, .caption, .col, .colgroup, .html, .td, .th, .tr: break
            default: tableEnd(t)
            }
        case .inRow:
            switch t.tag {
            case .tr: _ = closeRow()
            case .table: if closeRow() { modeEnd(t) }
            case .tbody, .tfoot, .thead:
                if hasInScope(t.tag, .table) && closeRow() { modeEnd(t) }
            case .body, .caption, .col, .colgroup, .html, .td, .th: break
            default: tableEnd(t)
            }
        case .inCell:
            switch t.tag {
            case .td, .th:
                if hasInScope(t.tag, .table) { _ = closeCell() }
            case .body, .caption, .col, .colgroup, .html: break
            case .table, .tbody, .tfoot, .thead, .tr:
                if hasInScope(t.tag, .table) && closeCell() { modeEnd(t) }
            default: bodyEnd(t)
            }
        case .inSelect, .inSelectInTable:
            selectEnd(t)
        case .afterBody:
            if t.tag == .html {
                if context == nil { mode = .afterAfterBody }   // fragment case: ignored
            } else { mode = .inBody; modeEnd(t) }
        case .afterAfterBody:
            mode = .inBody
            modeEnd(t)
        case .inFrameset:
            if t.tag == .frameset, let n = open.last, !isHTML(n, .html) {
                pop()
                if !currentIs(.frameset) { mode = .afterFrameset }
            }
        case .afterFrameset:
            if t.tag == .html { mode = .afterAfterFrameset }
        case .afterAfterFrameset:
            break
        case .inTemplate:
            if t.tag == .template { endTemplate() }
        }
    }

    func tableEnd(_ t: HTMLEndToken) {
        switch t.tag {
        case .table:
            if !hasInScope(.table, .table) { return }
            popUntil(.table)
            resetInsertionMode()
        case .template:
            endTemplate()
        case .body, .caption, .col, .colgroup, .html, .tbody, .td, .tfoot, .th, .thead, .tr:
            break
        default:
            fosterParenting = true
            bodyEnd(t)
            fosterParenting = false
        }
    }

    func selectEnd(_ t: HTMLEndToken) {
        switch t.tag {
        case .optgroup:
            if currentIs(.option), open.count >= 2, isHTML(open[open.count - 2], .optgroup) { pop() }
            if currentIs(.optgroup) { pop() }
        case .option:
            if currentIs(.option) { pop() }
        case .select:
            if hasInScope(.select, .select) { popUntil(.select); resetInsertionMode() }
        case .template:
            endTemplate()
        case .caption, .table, .tbody, .tfoot, .thead, .tr, .td, .th:
            if mode == .inSelectInTable {
                if hasInScope(t.tag, .table) {
                    popUntil(.select)
                    resetInsertionMode()
                    modeEnd(t)
                }
            } else { bodyEnd(t) }
        default: bodyEnd(t)
        }
    }

    func bodyEnd(_ t: HTMLEndToken) {
        switch t.tag {
        case .body:
            if hasInScope(.body) { mode = .afterBody }
        case .html:
            if hasInScope(.body) { mode = .afterBody; modeEnd(t) }
        case .address, .article, .aside, .blockquote, .button, .center, .details, .dialog, .dir, .div,
             .dl, .fieldset, .figcaption, .figure, .footer, .header, .hgroup, .listing, .main, .menu,
             .nav, .ol, .pre, .search, .section, .summary, .ul:
            if !hasInScope(t.tag) { return }
            generateImpliedEndTags()
            popUntil(t.tag)
        case .form:
            if templateOnStack {
                if !hasInScope(.form) { return }
                generateImpliedEndTags()
                popUntil(.form)
                return
            }
            let node = formElement
            formElement = nil
            guard let f = node, hasNodeInScope(f) else { return }
            generateImpliedEndTags()
            removeFromOpen(f)
        case .p:
            if !hasInScope(.p, .button) { _ = insertHTMLNamed(.p, "p") }
            closePElement()
        case .li:
            if !hasInScope(.li, .listItem) { return }
            generateImpliedEndTags(except: .li)
            popUntil(.li)
        case .dd, .dt:
            if !hasInScope(t.tag) { return }
            generateImpliedEndTags(except: t.tag)
            popUntil(t.tag)
        case .h1, .h2, .h3, .h4, .h5, .h6:
            if !hasHeadingInScope() { return }
            generateImpliedEndTags()
            popUntilHeading()
        case .a, .b, .big, .code, .em, .font, .i, .nobr, .s, .small, .strike, .strong, .tt, .u:
            adoptionAgency(t.tag, t.name)
        case .applet, .marquee, .object:
            if !hasInScope(t.tag) { return }
            generateImpliedEndTags()
            popUntil(t.tag)
            clearFormattingToMarker()
        case .br:
            bodyStart(HTMLStartToken(name: "br", tag: .br, attrs: [], selfClosing: false))
        case .template:
            endTemplate()
        default:
            anyOtherEndTag(t.name, t.tag)
        }
    }

    // --------------------------------------------------- foreign content

    func insertForeign(_ t: HTMLStartToken, _ ns: HTMLNamespace) {
        var name = t.name
        var attrs = t.attrs
        if ns == .svg, let f = htmlSVGTagName(name) { name = f }
        var i = 0
        while i < attrs.count {
            let n = attrs[i].name
            if ns == .svg, let f = htmlSVGAttrName(n) { attrs[i].name = f }
            else if ns == .mathml && n == "definitionurl" { attrs[i].name = "definitionURL" }
            if htmlIsForeignAdjustedAttr(attrs[i].name) { attrs[i].isNamespaced = true }
            i += 1
        }
        insertElement(name: name, tag: .unknown, ns: ns, attrs: attrs, push: !t.selfClosing)
    }

    func foreignChar(_ c: UInt32) {
        if c == 0 { insertCharacter(0xfffd); return }
        insertCharacter(c)
        if !htmlIsSpace(c) { framesetOK = false }
    }

    func foreignStart(_ t: HTMLStartToken) {
        var breakout = false
        switch t.name {
        case "b", "big", "blockquote", "body", "br", "center", "code", "dd", "div", "dl", "dt", "em",
             "embed", "h1", "h2", "h3", "h4", "h5", "h6", "head", "hr", "i", "img", "li", "listing",
             "menu", "meta", "nobr", "ol", "p", "pre", "ruby", "s", "small", "span", "strong", "strike",
             "sub", "sup", "table", "tt", "u", "ul", "var":
            breakout = true
        case "font":
            for a in t.attrs where a.name == "color" || a.name == "face" || a.name == "size" { breakout = true }
        default: break
        }
        if breakout {
            while let n = open.last {
                if n.namespace == .html || isMathTextIntegrationPoint(n) || isHTMLIntegrationPoint(n) { break }
                open.removeLast()
            }
            modeStart(t)
            return
        }
        let ns = adjustedCurrent?.namespace ?? .html
        insertForeign(t, ns)
    }

    func foreignEnd(_ t: HTMLEndToken) {
        if t.name == "br" || t.name == "p" {
            while let n = open.last {
                if n.namespace == .html || isMathTextIntegrationPoint(n) || isHTMLIntegrationPoint(n) { break }
                open.removeLast()
            }
            modeEnd(t)
            return
        }
        var idx = open.count - 1
        if idx < 0 { return }
        var node = open[idx]
        while true {
            if idx == 0 { return }
            if htmlLowerASCII(node.name) == t.name {
                while open.count > idx { open.removeLast() }
                return
            }
            idx -= 1
            node = open[idx]
            if node.namespace != .html { continue }
            modeEnd(t)
            return
        }
    }
}
