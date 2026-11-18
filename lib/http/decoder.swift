// Content-Encoding pipeline: how a decoder (lib/inflate, written separately)
// is plugged in. lib/http does not depend on inflate.
//
// The parser hands out raw (still content-encoded, but de-chunked) body
// bytes. To decode:
//
//   1. On .head(h), look at h.contentEncoding (.gzip / .deflate / .identity /
//      .unknown). Send "Accept-Encoding: gzip, deflate" (the default).
//   2. Make a decoder that conforms to HTTPBodyDecoder, e.g. a thin wrapper
//      around the inflate lib's streaming/one-shot API:
//
//        struct InflateBodyDecoder: HTTPBodyDecoder {
//            var buffer: [UInt8] = []        // one-shot inflate: collect, then run
//            let kind: HTTPContentEncoding
//            mutating func decode(_ input: [UInt8], final: Bool, into out: inout [UInt8]) -> Bool {
//                buffer += input
//                if !final { return true }
//                guard let r = inflateGzipOrZlib(buffer, kind) else { return false }
//                out += r; return true
//            }
//        }
//
//   3. Feed it through an HTTPBodySink<InflateBodyDecoder>: push(raw) for each
//      .body event and finish() on .complete; decoded bytes accumulate in
//      sink.output. With no decoder (identity) bytes pass straight through.
//
// For a whole-buffer response, httpDecodeBody(raw:encoding:decode:) does the
// same with a closure. decode returning nil (corrupt data) makes the sink
// fail; the caller then shows an error page.

protocol HTTPBodyDecoder {
    /// Consume `input` (possibly empty) and append decoded bytes to `out`.
    /// `final` is true on the last call. Return false on corrupt data.
    mutating func decode(_ input: [UInt8], final: Bool, into out: inout [UInt8]) -> Bool
}

/// Does nothing: the identity encoding.
struct HTTPIdentityDecoder: HTTPBodyDecoder {
    init() {}
    mutating func decode(_ input: [UInt8], final: Bool, into out: inout [UInt8]) -> Bool {
        out += input
        return true
    }
}

/// Collects a response body, decoding it on the way if given a decoder.
struct HTTPBodySink<D: HTTPBodyDecoder> {
    private var decoder: D?
    private(set) var output: [UInt8] = []
    private(set) var failed = false
    /// Cap on decoded size (decompression bombs).
    var maxOutput: Int

    init(decoder: D?, maxOutput: Int = 512 * 1024 * 1024) {
        self.decoder = decoder
        self.maxOutput = maxOutput
    }

    /// Returns false once the data is corrupt or too large.
    @discardableResult
    mutating func push(_ raw: [UInt8]) -> Bool {
        if failed { return false }
        if decoder == nil {
            output += raw
        } else {
            var d = decoder!
            if !d.decode(raw, final: false, into: &output) { failed = true }
            decoder = d
        }
        if output.count > maxOutput { failed = true }
        return !failed
    }

    @discardableResult
    mutating func finish() -> Bool {
        if failed { return false }
        if var d = decoder {
            if !d.decode([], final: true, into: &output) { failed = true }
            decoder = d
        }
        if output.count > maxOutput { failed = true }
        return !failed
    }
}

/// Whole-buffer decode with a closure: `decode(raw, encoding)` runs the
/// inflate lib (nil on corrupt data). Identity returns the input; an
/// unrecognized or stacked encoding returns nil.
func httpDecodeBody(raw: [UInt8], encoding: HTTPContentEncoding,
                    decode: ([UInt8], HTTPContentEncoding) -> [UInt8]?) -> [UInt8]? {
    switch encoding {
    case .identity: return raw
    case .gzip, .deflate: return decode(raw, encoding)
    case .brotli, .unknown: return nil
    }
}

/// Everything a simple (non-streaming) consumer needs: head, trailers and the
/// raw body gathered from parser events.
struct HTTPResponseCollector {
    private(set) var head: HTTPResponseHead? = nil
    private(set) var rawBody: [UInt8] = []
    private(set) var trailers: [HTTPHeader] = []
    private(set) var isComplete = false
    private(set) var keepAlive = false
    private(set) var error: HTTPParseError? = nil

    init() {}

    mutating func handle(_ e: HTTPParseEvent) {
        switch e {
        case .head(let h): head = h
        case .body(let b): rawBody += b
        case .trailers(let t): trailers = t
        case .complete(let k): isComplete = true; keepAlive = k
        case .error(let x): error = x
        }
    }

    mutating func handle(_ events: [HTTPParseEvent]) { for e in events { handle(e) } }
}
