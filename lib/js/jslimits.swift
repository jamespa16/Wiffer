// JSLimits: every resource cap in lib/js, in one place (ROADMAP Part 9,
// "Values, objects and memory" -> Limits). Shared by the lexer/parser, the
// compiler, the VM, the heap and the built-ins; an embedder builds one and
// hands it to the runtime/realm (the browser tightens some of them).
//
// Contract:
//   - Hitting a limit throws a catchable RangeError (string length, array
//     length, call depth, native nesting) or a SyntaxError (source size,
//     AST depth), except the heap cap and the regex step budget, which are
//     an uncatchable termination (JSTerminationReason). Nothing traps.
//   - `JSLimits()` is the default for a browser realm; `JSLimits.small` is
//     for tests and fuzzers (cheap to hit).
//   - JSHeap reads `heapBytes` and `maxStringLength` (it refuses to build a
//     longer string); the VM owns `maxCallDepth`, `maxNativeNesting`,
//     `interruptInterval`; the parser owns `maxSourceBytes` and
//     `maxASTDepth`, `maxParseStackBytes`, `maxASTHeight`, `maxASTNodes`; the RegExp engine owns `maxRegexSteps`.

public struct JSLimits {
    /// Live bytes a heap (one realm) may hold after a full collection
    /// before the script is terminated. Default 256 MiB.
    public var heapBytes: Int
    /// Longest string, in UTF-16 code units (V8 uses 2^29 - 24).
    public var maxStringLength: Int
    /// Largest array `length` the engine materializes in a dense element
    /// store; beyond it elements go sparse. (`length` itself may be up to
    /// 2^32 - 1 as the spec says; this caps memory, not semantics.)
    public var maxDenseArrayLength: Int
    /// Largest array length a single operation may create element by
    /// element (Array(n).fill, join, ...): over it is a RangeError.
    public var maxArrayLength: Int
    /// JS-to-JS call depth (VM frames).
    public var maxCallDepth: Int
    /// Native -> JS re-entry depth (sort comparators, getters, toString...).
    public var maxNativeNesting: Int
    /// Script source size in bytes.
    public var maxSourceBytes: Int
    /// Parser/compiler nesting depth (expressions, statements, scopes).
    public var maxASTDepth: Int
    /// Stack bytes the parser may use below its entry point (frame sizes
    /// vary by production and target: about 100 to 900 bytes per nesting
    /// level on arm64 -Osize). Deeper input is a SyntaxError. The default
    /// leaves half of Wiffer's 512 KiB user stack to the caller.
    public var maxParseStackBytes: Int
    /// Height of a finished AST (the parser checks it after parsing, so the
    /// compiler may recurse once per level); left-associative chains such as
    /// `a + b + c ...` add a level per operator without parser recursion.
    public var maxASTHeight: Int
    /// AST nodes per script.
    public var maxASTNodes: Int
    /// Backtracking steps per regular expression match.
    public var maxRegexSteps: Int
    /// The VM checks its interrupt budget at least every this many
    /// instructions (also at backward jumps and calls).
    public var interruptInterval: Int
    /// Largest BigInt, in bits (RangeError past it: `2n ** 10000000n`).
    /// Multiplication is Karatsuba, division and toString are quadratic, so
    /// this also bounds the time one operation can take.
    public var maxBigIntBits: Int

    public init(heapBytes: Int = 256 << 20,
                maxStringLength: Int = (1 << 29) - 24,
                maxDenseArrayLength: Int = 1 << 26,
                maxArrayLength: Int = (1 << 32) - 1,
                maxCallDepth: Int = 10_000,
                maxNativeNesting: Int = 64,
                maxSourceBytes: Int = 64 << 20,
                maxASTDepth: Int = 1_000,
                maxParseStackBytes: Int = 256 << 10,
                maxASTHeight: Int = 2_000,
                maxASTNodes: Int = 20_000_000,
                maxRegexSteps: Int = 10_000_000,
                interruptInterval: Int = 10_000,
                maxBigIntBits: Int = 1 << 18) {
        self.heapBytes = heapBytes
        self.maxStringLength = maxStringLength
        self.maxDenseArrayLength = maxDenseArrayLength
        self.maxArrayLength = maxArrayLength
        self.maxCallDepth = maxCallDepth
        self.maxNativeNesting = maxNativeNesting
        self.maxSourceBytes = maxSourceBytes
        self.maxASTDepth = maxASTDepth
        self.maxParseStackBytes = maxParseStackBytes
        self.maxASTHeight = maxASTHeight
        self.maxASTNodes = maxASTNodes
        self.maxRegexSteps = maxRegexSteps
        self.interruptInterval = interruptInterval
        self.maxBigIntBits = maxBigIntBits
    }

    /// Tight limits for tests and fuzzing.
    public static var small: JSLimits {
        JSLimits(heapBytes: 16 << 20, maxStringLength: 1 << 20, maxDenseArrayLength: 1 << 16,
                 maxArrayLength: 1 << 20, maxCallDepth: 500,
                 maxNativeNesting: 16, maxSourceBytes: 1 << 20, maxASTDepth: 200, maxASTHeight: 400,
                 maxASTNodes: 1 << 20,
                 maxRegexSteps: 100_000, interruptInterval: 1_000, maxBigIntBits: 1 << 14)
    }
}

/// Why a script is being terminated. Termination is uncatchable: the VM
/// unwinds every frame without running `catch` or `finally`.
public enum JSTerminationReason: Equatable {
    /// The heap stayed over `JSLimits.heapBytes` after a full collection.
    case heapLimit
    /// The embedder's interrupt budget ran out (the browser's ~5 s).
    case interrupted
    /// A regular expression match ran out of `maxRegexSteps`.
    case regexSteps
}
