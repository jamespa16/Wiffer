// The test262 execution runner's skip lists (Phase 9D), in one place.
// A skipped test is not counted as a failure, so keep these honest: when a
// phase lands a feature, delete its tag here, run `./run.sh --test262`, and
// raise the floors (see jstest262_run.swift).

/// `features:` tags whose tests are skipped.
let jsTest262RunSkipFeatures: [String] = [
    // Not planned for Wiffer (no threads, no Intl, no host-defined oddities).
    "Atomics", "SharedArrayBuffer", "Atomics.waitAsync", "Atomics.pause",
    "Temporal", "IsHTMLDDA", "ShadowRealm", "tail-call-optimization",
    "decorators", "cross-realm", "FinalizationRegistry.prototype.cleanupSome",
    "host-gc-required", "Intl", "Intl.Locale", "Intl-enumeration", "intl-normative-optional",
    "legacy-regexp", "uint8array-base64", "upsert", "joint-iteration", "iterator-sequencing",
    "Math.sumPrecise", "canonical-tz", "immutable-arraybuffer",
    "RegExp.escape", "Error.isError", "Array.fromAsync",
    "import-attributes", "import-assertions", "json-modules", "source-phase-imports",
    "source-phase-imports-module-source", "import-defer", "import-text", "import-bytes",
    "explicit-resource-management", "regexp-modifiers", "regexp-duplicate-named-groups",
    "iterator-helpers", "json-parse-with-source",
    "await-dictionary", "nonextensible-applies-to-private", "Symbol.dispose", "Symbol.asyncDispose",
    // Not implemented yet: delete the tag when the phase lands.
]

/// Source substrings that need a `$262` feature the embedding API cannot
/// give yet; the test is skipped with that reason. (`$262.createRealm`
/// needs cross-heap value sharing; `$262.agent` needs threads.)
let jsTest262RunSkipSource: [(needle: String, reason: String)] = [
    ("$262.createRealm", "$262.createRealm"),
    ("$262.agent", "$262.agent"),
    ("$262.IsHTMLDDA", "IsHTMLDDA"),
    ("$262.AbstractModuleSource", "AbstractModuleSource"),
    // Exhaustive code point sweeps (property escapes, character class escapes): seconds per test.
    ("regExpUtils.js", "slow: code point sweep"),
]
