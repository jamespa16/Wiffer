// Incremental HTTP/1.x response parser.
//
//   var parser = HTTPResponseParser(requestMethod: Array("GET".utf8))
//   var events: [HTTPParseEvent] = []
//   parser.feed(bytesFromSocket, &events)     // any chunking, byte by byte too
//   ...
//   parser.finish(&events)                    // when the peer closes
//
// Events come out in order: .head once, .body(raw bytes) any number of times
// (de-chunked, still content-encoded), .trailers at most once, then exactly
// one of .complete(keepAlive:) or .error. After completion, any bytes that
// were fed beyond the message are in `leftover`. Informational 1xx responses
// (except 101) are skipped. Every limit is enforced and reported as .error;
// the parser never traps.

struct HTTPLimits {
    var maxLineLength = 16 * 1024
    var maxHeaderCount = 200
    var maxHeaderBytes = 256 * 1024
    var maxChunkSize = 1 << 30
    var maxBodySize = 256 * 1024 * 1024
    init() {}
}

enum HTTPParseError: Error, Equatable {
    case lineTooLong, tooManyHeaders, headersTooLarge
    case badStatusLine, badHeader, badContentLength, badChunk
    case bodyTooLarge
    case truncated
}

enum HTTPContentEncoding: Equatable {
    case identity, gzip, deflate, brotli, unknown
}

struct HTTPResponseHead {
    var minorVersion: Int = 1
    var status: Int = 0
    var reason: [UInt8] = []
    var headers: [HTTPHeader] = []

    func header(_ name: String) -> [UInt8]? { headers.httpValue(name) }
    var contentType: [UInt8]? { header("Content-Type") }
    var location: [UInt8]? { header("Location") }
    var setCookies: [[UInt8]] { headers.httpValues("Set-Cookie") }

    /// Content-Encoding values in the order they were applied (decode in
    /// reverse). Empty for identity.
    var contentEncodings: [HTTPContentEncoding] {
        var out: [HTTPContentEncoding] = []
        for v in headers.httpValues("Content-Encoding") {
            for item in httpSplitList(v) {
                let t = httpLowercased(item)
                if t == Array("gzip".utf8) || t == Array("x-gzip".utf8) { out.append(.gzip) }
                else if t == Array("deflate".utf8) { out.append(.deflate) }
                else if t == Array("br".utf8) { out.append(.brotli) }
                else if t == Array("identity".utf8) {}
                else { out.append(.unknown) }
            }
        }
        return out
    }

    /// The single encoding to decode, or .identity; .unknown if several or
    /// unrecognized.
    var contentEncoding: HTTPContentEncoding {
        let e = contentEncodings
        if e.isEmpty { return .identity }
        return e.count == 1 ? e[0] : .unknown
    }

    private func connectionTokens() -> [[UInt8]] {
        var out: [[UInt8]] = []
        for v in headers.httpValues("Connection") { for t in httpSplitList(v) { out.append(httpLowercased(t)) } }
        return out
    }

    /// Whether the connection may be reused, ignoring body framing.
    var wantsKeepAlive: Bool {
        let toks = connectionTokens()
        if toks.contains(Array("close".utf8)) { return false }
        if minorVersion >= 1 { return true }
        return toks.contains(Array("keep-alive".utf8))
    }
}

enum HTTPBodyFraming: Equatable {
    case none
    case contentLength(Int)
    case chunked
    case untilClose
}

enum HTTPParseEvent {
    case head(HTTPResponseHead)
    case body([UInt8])
    case trailers([HTTPHeader])
    case complete(keepAlive: Bool)
    case error(HTTPParseError)
}

struct HTTPResponseParser {
    private enum State: Equatable {
        case head
        case fixed(Int)
        case chunkSize
        case chunkData(Int)
        case chunkDataEnd(sawCR: Bool)
        case trailers
        case untilClose
        case done
        case failed
    }

    private var state = State.head
    private let isHead: Bool
    private let limits: HTTPLimits
    private var line: [UInt8] = []
    private var current = HTTPResponseHead()
    private var haveStatus = false
    private var headBytes = 0
    private var headerCount = 0
    private var trailerList: [HTTPHeader] = []
    private var bodyBytes = 0
    private var keepAlive = false
    private var leadingBlank = 0

    /// Bytes fed after the end of the message (pipelining / next response).
    private(set) var leftover: [UInt8] = []
    private(set) var head: HTTPResponseHead? = nil
    private(set) var framing: HTTPBodyFraming = .none

    var isDone: Bool { state == .done }
    var hasFailed: Bool { state == .failed }
    var isFinished: Bool { state == .done || state == .failed }

    init(requestMethod: [UInt8] = Array("GET".utf8), limits: HTTPLimits = HTTPLimits()) {
        isHead = httpEqualsIgnoreCase(requestMethod, "HEAD")
        self.limits = limits
    }

    private mutating func fail(_ e: HTTPParseError, _ events: inout [HTTPParseEvent]) {
        state = .failed
        line = []
        events.append(.error(e))
    }

    private mutating func complete(_ events: inout [HTTPParseEvent]) {
        state = .done
        events.append(.complete(keepAlive: keepAlive))
    }

    mutating func feed(_ data: [UInt8], _ events: inout [HTTPParseEvent]) {
        var i = 0
        let n = data.count
        while i < n {
            switch state {
            case .done:
                leftover += data[i...]
                return
            case .failed:
                return
            case .head, .chunkSize, .trailers:
                let c = data[i]
                i += 1
                if c != 0x0a {
                    line.append(c)
                    let lim = state == .chunkSize ? 1024 : limits.maxLineLength
                    if line.count > lim { fail(.lineTooLong, &events); return }
                    if state != .chunkSize {
                        headBytes += 1
                        if headBytes > limits.maxHeaderBytes { fail(.headersTooLarge, &events); return }
                    }
                    continue
                }
                if state != .chunkSize { headBytes += 1 }
                if let l = line.last, l == 0x0d { line.removeLast() }
                let l = line
                line = []
                switch state {
                case .head: handleHeadLine(l, &events)
                case .chunkSize: handleChunkSize(l, &events)
                default: handleTrailerLine(l, &events)
                }
            case .fixed(let remaining):
                let take = min(remaining, n - i)
                events.append(.body(Array(data[i..<(i + take)])))
                i += take
                bodyBytes += take
                if remaining - take == 0 { complete(&events) } else { state = .fixed(remaining - take) }
            case .chunkData(let remaining):
                let take = min(remaining, n - i)
                bodyBytes += take
                if bodyBytes > limits.maxBodySize { fail(.bodyTooLarge, &events); return }
                events.append(.body(Array(data[i..<(i + take)])))
                i += take
                state = remaining - take == 0 ? .chunkDataEnd(sawCR: false) : .chunkData(remaining - take)
            case .chunkDataEnd(let sawCR):
                let c = data[i]
                i += 1
                if c == 0x0d && !sawCR { state = .chunkDataEnd(sawCR: true) }
                else if c == 0x0a { state = .chunkSize }
                else { fail(.badChunk, &events); return }
            case .untilClose:
                bodyBytes += n - i
                if bodyBytes > limits.maxBodySize { fail(.bodyTooLarge, &events); return }
                events.append(.body(Array(data[i...])))
                i = n
            }
        }
    }

    /// The peer closed the connection.
    mutating func finish(_ events: inout [HTTPParseEvent]) {
        switch state {
        case .untilClose:
            keepAlive = false
            complete(&events)
        case .done, .failed:
            break
        default:
            fail(.truncated, &events)
        }
    }

    // MARK: lines

    private mutating func handleHeadLine(_ l: [UInt8], _ events: inout [HTTPParseEvent]) {
        if !haveStatus {
            if l.isEmpty {
                // tolerate a few stray blank lines before the status line
                leadingBlank += 1
                if leadingBlank > 4 { fail(.badStatusLine, &events) }
                return
            }
            guard parseStatusLine(l) else { fail(.badStatusLine, &events); return }
            haveStatus = true
            return
        }
        if l.isEmpty { headersComplete(&events); return }
        headerCount += 1
        if headerCount > limits.maxHeaderCount { fail(.tooManyHeaders, &events); return }
        if l[0] == 0x20 || l[0] == 0x09 {
            // obs-fold: continuation of the previous header
            guard !current.headers.isEmpty else { fail(.badHeader, &events); return }
            let t = httpTrim(l)
            if !t.isEmpty {
                let k = current.headers.count - 1
                if !current.headers[k].value.isEmpty { current.headers[k].value.append(0x20) }
                current.headers[k].value += t
            }
            return
        }
        guard let h = parseHeaderLine(l) else { fail(.badHeader, &events); return }
        current.headers.append(h)
    }

    private func parseHeaderLine(_ l: [UInt8]) -> HTTPHeader? {
        var colon = -1
        for (k, c) in l.enumerated() where c == 0x3a { colon = k; break }
        if colon <= 0 { return nil }
        for k in 0..<colon where !httpIsTokenByte(l[k]) { return nil }
        for c in l where c == 0x00 { return nil }
        return HTTPHeader(Array(l[0..<colon]), httpTrim(Array(l[(colon + 1)...])))
    }

    private mutating func parseStatusLine(_ l: [UInt8]) -> Bool {
        // HTTP/1.x SP 3DIGIT [SP reason]
        guard l.count >= 12, l[0] == 0x48, l[1] == 0x54, l[2] == 0x54, l[3] == 0x50, l[4] == 0x2f,
              l[5] == 0x31, l[6] == 0x2e, l[7] >= 0x30, l[7] <= 0x39, l[8] == 0x20 || l.count == 12 else { return false }
        guard l[8] == 0x20 else { return false }
        var status = 0
        for k in 9..<12 {
            guard l[k] >= 0x30 && l[k] <= 0x39 else { return false }
            status = status * 10 + Int(l[k] - 0x30)
        }
        if status < 100 { return false }
        if l.count > 12 && l[12] != 0x20 { return false }
        current = HTTPResponseHead()
        current.minorVersion = Int(l[7] - 0x30)
        current.status = status
        current.reason = l.count > 13 ? Array(l[13...]) : []
        headerCount = 0
        headBytes = l.count + 1
        return true
    }

    private mutating func headersComplete(_ events: inout [HTTPParseEvent]) {
        let st = current.status
        if st >= 100 && st < 200 && st != 101 {
            // interim response: discard and wait for the real one
            haveStatus = false
            current = HTTPResponseHead()
            return
        }
        var fr: HTTPBodyFraming
        let te = current.headers.httpValues("Transfer-Encoding")
        if isHead || st == 204 || st == 304 || st == 101 || (st >= 100 && st < 200) {
            fr = .none
        } else if !te.isEmpty {
            var last: [UInt8] = []
            for v in te { for t in httpSplitList(v) { last = httpLowercased(t) } }
            fr = last == Array("chunked".utf8) ? .chunked : .untilClose
        } else if current.headers.httpHas("Content-Length") {
            var len: Int? = nil
            for v in current.headers.httpValues("Content-Length") {
                for item in httpSplitList(v) {
                    guard let x = httpParseDecimal(item, limit: limits.maxBodySize) else {
                        // distinguish "too big" from "garbage"
                        if httpParseDecimal(item) != nil { fail(.bodyTooLarge, &events) }
                        else { fail(.badContentLength, &events) }
                        return
                    }
                    if let prev = len, prev != x { fail(.badContentLength, &events); return }
                    len = x
                }
            }
            guard let l = len else { fail(.badContentLength, &events); return }
            fr = .contentLength(l)
        } else {
            fr = .untilClose
        }
        framing = fr
        head = current
        keepAlive = current.wantsKeepAlive && fr != .untilClose
        events.append(.head(current))
        switch fr {
        case .none: complete(&events)
        case .contentLength(let l): if l == 0 { complete(&events) } else { state = .fixed(l) }
        case .chunked: state = .chunkSize
        case .untilClose: state = .untilClose
        }
    }

    private mutating func handleChunkSize(_ l: [UInt8], _ events: inout [HTTPParseEvent]) {
        var size = 0
        var digits = 0
        for c in l {
            let v = urlHexValue(c)
            if v < 0 { break }
            size = size * 16 + v
            digits += 1
            if digits > 12 || size > limits.maxChunkSize { fail(.badChunk, &events); return }
        }
        if digits == 0 { fail(.badChunk, &events); return }
        // anything after the digits must be a chunk extension or whitespace
        if digits < l.count {
            let c = l[digits]
            if c != 0x3b && c != 0x20 && c != 0x09 { fail(.badChunk, &events); return }
        }
        if size == 0 { state = .trailers; headerCount = 0; return }
        if bodyBytes + size > limits.maxBodySize { fail(.bodyTooLarge, &events); return }
        state = .chunkData(size)
    }

    private mutating func handleTrailerLine(_ l: [UInt8], _ events: inout [HTTPParseEvent]) {
        if l.isEmpty {
            if !trailerList.isEmpty { events.append(.trailers(trailerList)) }
            complete(&events)
            return
        }
        headerCount += 1
        if headerCount > limits.maxHeaderCount { fail(.tooManyHeaders, &events); return }
        if l[0] == 0x20 || l[0] == 0x09 {
            guard !trailerList.isEmpty else { fail(.badHeader, &events); return }
            let k = trailerList.count - 1
            trailerList[k].value.append(0x20)
            trailerList[k].value += httpTrim(l)
            return
        }
        guard let h = parseHeaderLine(l) else { fail(.badHeader, &events); return }
        trailerList.append(h)
    }
}
