// Session history: a list of entries and a current index. Navigating drops
// the forward entries; back and forward move the index. Each entry keeps its
// scroll position (saved when leaving it) and, for a form POST, the request
// to repeat.

struct BrowserHistoryEntry {
    var url: String
    var title: String = ""
    var scrollX = 0
    var scrollY = 0
    /// A POST to repeat on back/forward/reload (nil: a GET).
    var method = "GET"
    var body: [UInt8] = []
    var contentType: String? = nil

    init(url: String) { self.url = url }
}

struct BrowserHistory {
    private(set) var entries: [BrowserHistoryEntry] = []
    /// Index of the current entry (-1: empty).
    private(set) var index = -1
    var maxEntries = 100

    init() {}

    var current: BrowserHistoryEntry? { index >= 0 && index < entries.count ? entries[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index + 1 < entries.count }

    /// A new page: it becomes current and the forward entries are dropped.
    mutating func push(_ e: BrowserHistoryEntry) {
        if index + 1 < entries.count { entries.removeSubrange((index + 1)...) }
        entries.append(e)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        index = entries.count - 1
    }

    /// Replace the current entry (a redirect, or a reload that landed elsewhere).
    mutating func replaceCurrent(_ e: BrowserHistoryEntry) {
        if index < 0 { push(e); return }
        entries[index] = e
    }

    /// Save where the user was on the current entry.
    mutating func saveScroll(x: Int, y: Int) {
        guard index >= 0 else { return }
        entries[index].scrollX = x
        entries[index].scrollY = y
    }

    mutating func setTitle(_ t: String) {
        guard index >= 0 else { return }
        entries[index].title = t
    }

    mutating func setURL(_ u: String) {
        guard index >= 0 else { return }
        entries[index].url = u
    }

    /// Move back one entry; the entry to show, or nil at the start.
    mutating func back() -> BrowserHistoryEntry? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    mutating func forward() -> BrowserHistoryEntry? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}
