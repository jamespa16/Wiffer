// Built-in pages: about:home (bookmarks), about:blank, error pages,
// view-source, and wrappers that show plain text, images and directories as
// documents. All are HTML strings the loader parses like any other page.

/// Escape text for HTML content and attribute values.
func browserEscapeHTML(_ s: String) -> String {
    var out = ""
    for u in s.unicodeScalars {
        switch u {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.unicodeScalars.append(u)
        }
    }
    return out
}

/// Bytes as text for display (UTF-8 with replacement characters).
func browserText(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

struct BrowserBookmark {
    var title: String
    var url: String
    var note: String
}

/// The target sites of Phase 8I, and the local test pages.
let browserBookmarks: [BrowserBookmark] = [
    BrowserBookmark(title: "info.cern.ch", url: "http://info.cern.ch/", note: "the first web site"),
    BrowserBookmark(title: "example.com", url: "https://example.com/", note: "IANA's example domain"),
    BrowserBookmark(title: "DuckDuckGo Lite", url: "https://lite.duckduckgo.com/lite/", note: "search without JavaScript"),
    BrowserBookmark(title: "Wikipedia", url: "https://en.wikipedia.org/wiki/Web_browser", note: "an article"),
    BrowserBookmark(title: "Wikipedia search", url: "https://en.wikipedia.org/w/index.php?search=operating+system",
                    note: "a search"),
    BrowserBookmark(title: "Wikipedia: tables and images", url: "https://en.wikipedia.org/wiki/Solar_System",
                    note: "infobox, tables, pictures"),
    BrowserBookmark(title: "Hacker News", url: "https://news.ycombinator.com/", note: "tables everywhere"),
    BrowserBookmark(title: "NPR text", url: "https://text.npr.org/", note: "text-only news"),
    BrowserBookmark(title: "CNN lite", url: "https://lite.cnn.com/", note: "text-only news"),
    BrowserBookmark(title: "Wiffer on GitHub", url: "https://github.com/", note: "heavy CSS (stretch)"),
    BrowserBookmark(title: "Local test page", url: "file:///www/index.html", note: "from the RAM filesystem"),
]

let browserHomeURL = "about:home"

/// about:home: bookmarks and a search box.
func browserHomePage() -> String {
    var s = """
    <!DOCTYPE html><html><head><title>Home</title><style>
    body { font-family: sans-serif; margin: 24px 40px; background: #f6f7f9; color: #1a1a1a }
    h1 { font-size: 26px; color: #1e5aa8; margin-bottom: 4px }
    .sub { color: #555; margin-top: 0 }
    ul { padding: 0; list-style: none }
    li { margin: 6px 0; padding: 8px 12px; background: #fff; border: 1px solid #d6dae0 }
    li a { font-weight: bold; color: #1e5aa8 }
    li span { color: #666; font-size: 13px }
    form { margin: 16px 0 }
    </style></head><body>
    <h1>Wiffer browser</h1>
    <p class="sub">Type an address above, or pick a site.</p>
    <form action="https://lite.duckduckgo.com/lite/" method="get">
    <input type="search" name="q" size="40" placeholder="Search DuckDuckGo"> <input type="submit" value="Search">
    </form>
    <ul>
    """
    for b in browserBookmarks {
        s += "<li><a href=\"" + browserEscapeHTML(b.url) + "\">" + browserEscapeHTML(b.title) + "</a> <span>"
            + browserEscapeHTML(b.note) + " &mdash; " + browserEscapeHTML(b.url) + "</span></li>\n"
    }
    s += "</ul></body></html>"
    return s
}

let browserBlankPage = "<!DOCTYPE html><html><head><title></title></head><body></body></html>"

/// An error page: `title` is also the window title.
func browserErrorPage(title: String, detail: String, url: String) -> String {
    """
    <!DOCTYPE html><html><head><title>\(browserEscapeHTML(title))</title><style>
    body { font-family: sans-serif; margin: 48px; background: #fbfbfb; color: #222 }
    h1 { font-size: 24px; color: #a8321e }
    .url { font-family: monospace; color: #555; word-wrap: break-word }
    .box { border-left: 4px solid #a8321e; padding: 4px 16px; background: #fff }
    </style></head><body><div class="box">
    <h1>\(browserEscapeHTML(title))</h1>
    <p>\(browserEscapeHTML(detail))</p>
    <p class="url">\(browserEscapeHTML(url))</p>
    <p><a href="about:home">Home</a></p>
    </div></body></html>
    """
}

/// view-source: the source with line numbers.
func browserViewSourcePage(_ source: [UInt8], url: String, maxBytes: Int = 4 * 1024 * 1024) -> String {
    let cut = source.count > maxBytes
    let text = browserText(cut ? Array(source[0..<maxBytes]) : source)
    var s = "<!DOCTYPE html><html><head><title>view-source:" + browserEscapeHTML(url) + "</title><style>"
        + "body{margin:0;background:#fff}pre{font-family:monospace;font-size:13px;margin:8px;white-space:pre-wrap}"
        + ".n{color:#999}</style></head><body><pre>"
    var line = 1
    var cur = ""
    func flush() {
        var num = "\(line)"
        while num.utf8.count < 5 { num = " " + num }
        s += "<span class=\"n\">" + num + "</span>  " + browserEscapeHTML(cur) + "\n"
        line += 1
        cur = ""
    }
    for u in text.unicodeScalars {
        if u == "\n" { flush() } else if u != "\r" { cur.unicodeScalars.append(u) }
        if line > 200_000 { break }
    }
    if !cur.isEmpty { flush() }
    if cut { s += "\n(truncated)" }
    return s + "</pre></body></html>"
}

/// A text/plain resource as a document.
func browserPlainTextPage(_ body: [UInt8], title: String) -> String {
    "<!DOCTYPE html><html><head><title>" + browserEscapeHTML(title) + "</title></head><body><pre style=\"white-space:pre-wrap\">"
        + browserEscapeHTML(browserText(body)) + "</pre></body></html>"
}

/// An image resource as a document (the loader seeds the image from the response).
func browserImagePage(url: String, title: String) -> String {
    "<!DOCTYPE html><html><head><title>" + browserEscapeHTML(title) + "</title></head>"
        + "<body style=\"margin:0;background:#333\"><img src=\"" + browserEscapeHTML(url) + "\"></body></html>"
}

/// A directory listing for file:// URLs.
func browserDirectoryPage(path: String, entries: [(name: String, isDirectory: Bool, size: Int)]) -> String {
    var s = "<!DOCTYPE html><html><head><title>Index of " + browserEscapeHTML(path) + "</title></head>"
        + "<body style=\"font-family:sans-serif\"><h1>Index of " + browserEscapeHTML(path) + "</h1><ul>"
    if path != "/" { s += "<li><a href=\"../\">../</a></li>" }
    for e in entries {
        let n = e.name + (e.isDirectory ? "/" : "")
        let enc = String(decoding: urlPercentEncode(Array(e.name.utf8), .path), as: UTF8.self) + (e.isDirectory ? "/" : "")
        s += "<li><a href=\"" + browserEscapeHTML(enc) + "\">" + browserEscapeHTML(n) + "</a>"
        if !e.isDirectory { s += " <span style=\"color:#777\">(\(e.size) bytes)</span>" }
        s += "</li>"
    }
    return s + "</ul></body></html>"
}
