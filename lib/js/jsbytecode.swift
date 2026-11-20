// JS bytecode: the stack machine the compiler (jscompiler*.swift) emits and
// the VM (jsvm*.swift) runs (ROADMAP Phase 9B).
//
// Format. One function's code is a byte array: an opcode byte followed by
// its operands, little-endian, unaligned: u8, u16, u32 (constant, key,
// local or env index) and i32 (jump offsets, relative to the start of the
// NEXT instruction). `jsOpFormat(op)` gives the operand layout of every
// opcode, which is all the disassembler and the VM decoder need.
//
// Frame. A call frame owns a region of the VM's value stack:
//
//     [callee] [this] | arg/local 0 ... local nlocals-1 | operand stack ...
//                     ^ base                            ^ base + nlocals
//
// Parameters are locals 0..<nparams (missing arguments are undefined,
// extra ones are dropped after `arguments` and the rest array are built).
// Every other local starts as undefined. The compiler tracks the operand
// stack depth statically: every instruction has a fixed stack effect (call
// counts are operands), labels carry their depth, and a mismatch or a pop
// below zero is an internal compile error, never bad code. `maxStack` is
// the deepest point; the VM reserves it on entry.
//
// Environments. Bindings captured by closures (and every binding of a
// function that contains `with` or direct `eval`) live in heap
// environment objects (kind .environment):
//     slot 0 parent env (or undefined)    slot 1 scope info object
//     slot 2... the bindings, in declaration order
// The scope info object (kind .internalObject, built at compile time and
// kept in the constant pool) maps each named binding's atom to its slot
// (an int32: slot | constFlag | lexicalFlag) for dynamic name lookup, and
// its own `slots` are the initial values (undefined, or hole for TDZ
// bindings). Env flags: user0 = an object (`with`) environment whose slot 2
// is the object, user1 = a var scope (where sloppy direct eval declares its
// vars, as own properties of the env object).
//
// Constants. Each function has a constant pool (numbers, strings, nested
// function code objects, scope infos, template objects) and a key pool
// (JSPropertyKey for property names and global names). The pools live in a
// code object (kind .internalObject, flag user0, finalizer) whose slots
// hold every constant, so the GC keeps them alive; the JSCode Swift object
// is freed by the finalizer when the code object dies.
//
// Exceptions. `handlers` lists (start, end, target, depth) regions,
// innermost first. On a throw at pc, the first region containing pc wins:
// the operand stack is cut to `depth`, the exception value is pushed and
// execution continues at target. finally blocks are entered with
// (value, kind) on the stack: kind 0 normal, 1 throw (value = exception),
// 2... a break/continue/return the compiler routed through the finally;
// `finallyDispatch` ends the block.
//
// Lines. `lines` maps pcs to source byte offsets (entries sorted by pc;
// the entry at or before a pc applies); JSScriptSource turns offsets into
// line:column for stack traces.
//
// `jsDisassemble(code)` prints a function (and its nested functions) for
// tests and debugging.

enum JSOp: UInt8 {
    // Stack.
    case nop, pop, popN, dup, dup2, swap, rot3, rot4, over
    // Constants.
    case pushUndefined, pushNull, pushTrue, pushFalse, pushHole, pushInt, pushConst
    // Locals (u32 index; checked forms take a key for the message).
    case getLocal, putLocal, setLocal, getLocalChecked, putLocalChecked
    // Environments (u16 hops, u32 slot).
    case getEnv, putEnv, setEnv, getEnvChecked, putEnvChecked
    case pushEnv, popEnv, cloneEnv, saveEnv, restoreEnv, enterWith
    // Names (dynamic lookup through the env chain, then the global scope).
    case getName, getNameOrUndef, putName, getNameForCall, deleteName
    case getGlobal, getGlobalOrUndef, putGlobal, getGlobalForCall
    case declareVar, declareFunc, declareLex, initLex
    // Properties.
    case getField, putField, getElem, putElem, getFieldForCall, getElemForCall
    case deleteField, deleteElem, getSuperField, getSuperElem, putSuperField, putSuperElem
    // Literals.
    case newObject, newArray, defineField, defineElem, defineMethod, defineMethodElem
    case appendElem, appendHole, appendSpread, copyDataProps, objectRest, setProto
    case closure, newRegExp, templateObject, newClass, setHomeObject, setFieldInit
    // Operators.
    case add, sub, mul, div, mod, exp, shl, sar, shr, bitAnd, bitOr, bitXor
    case lt, gt, le, ge, eq, ne, strictEq, strictNe, instanceOf, inOp
    case neg, plus, not, bitNot, typeOf, inc, dec, toNumeric, toStringOp, toPropertyKey
    // Control.
    case jump, jumpIfTrue, jumpIfFalse, jumpIfTrueKeep, jumpIfFalseKeep, jumpIfNotNullishKeep
    case jumpIfNullish, jumpIfUndefinedKeep
    case call, callArray, construct, constructArray, directEval, superCall, superCallArray
    case ret, retUndefined, retDerived, throwOp, throwError
    // Iteration.
    case forInStart, forInNext, getIterator, iterNext, iterStepValue, iterRest, iterClose, iterCloseThrow
    // Function state.
    case loadThis, loadGlobalThis, loadNewTarget, loadCallee, loadHomeObject, runFieldInit
    case finallyDispatch, debugger
    case checkThisInit, checkObjectCoercible
    // Phase 9E: generators and async functions (jsgenerator.swift).
    case generatorStart, yield_, yieldRaw, asyncGenYield, await_, checkResume, resumeIsReturn
    case yieldStarCall, yieldStarResult, getAsyncIterator, asyncIterResult, asyncReturnCall, checkObject
    // Phase 9E: private names, computed fields and other gaps.
    case newPrivateName, getPrivate, putPrivate, definePrivate, hasPrivate, addPrivateBrand, setPrivateMethod
    case dup3, objectRestDynamic, directEvalArray, getterThisSwap
    // Phase 9E: modules (jsmodule.swift).
    case importMeta, dynamicImport, getModuleBinding
}

/// Operand layouts.
enum JSOpFormat {
    case none
    case u8            // a byte
    case u16           // argument counts
    case u32           // a constant, key or local index; popN count
    case i32           // pushInt value
    case jump          // i32 relative offset
    case u32u32        // checked local: index, key
    case env           // u16 hops, u32 slot
    case envKey        // u16 hops, u32 slot, u32 key
    case keyU8         // u32 key, u8 flags
    case u8u32         // throwError: u8 kind, u32 constant (message)
    case nullishJump   // i32 offset, u8 position from top, u8 values to pop
    case u32u32Const   // newRegExp: pattern, flags constants
    case table         // u16 n, then n i32 offsets (finallyDispatch)
    case jump2         // two i32 offsets (yieldStarResult: done, return)
}

@inline(__always) func jsOpFormat(_ op: JSOp) -> JSOpFormat {
    switch op {
    case .popN, .pushConst, .getLocal, .putLocal, .setLocal, .pushEnv, .saveEnv, .restoreEnv,
         .getName, .getNameOrUndef, .putName, .getNameForCall, .deleteName,
         .getGlobal, .getGlobalOrUndef, .putGlobal, .getGlobalForCall, .declareVar, .declareFunc, .initLex,
         .getField, .putField, .getFieldForCall, .deleteField, .getSuperField, .putSuperField,
         .defineField, .closure, .templateObject, .objectRest, .newArray, .getModuleBinding:
        return .u32
    case .pushInt: return .i32
    case .getLocalChecked, .putLocalChecked: return .u32u32
    case .getEnv, .putEnv, .setEnv: return .env
    case .getEnvChecked, .putEnvChecked: return .envKey
    case .declareLex, .defineMethod, .newClass, .newPrivateName: return .keyU8
    case .defineMethodElem, .asyncReturnCall, .setPrivateMethod: return .u8
    case .throwError: return .u8u32
    case .jump, .jumpIfTrue, .jumpIfFalse, .jumpIfTrueKeep, .jumpIfFalseKeep, .jumpIfNotNullishKeep,
         .jumpIfUndefinedKeep, .forInNext, .iterNext, .checkResume, .resumeIsReturn, .yieldStarCall,
         .asyncIterResult:
        return .jump
    case .yieldStarResult: return .jump2
    case .jumpIfNullish: return .nullishJump
    case .call, .construct, .directEval, .superCall, .directEvalArray: return .u16
    case .newRegExp: return .u32u32Const
    case .finallyDispatch: return .table
    default: return .none
    }
}

/// Instruction length in bytes for fixed formats (table: variable).
@inline(__always) func jsFormatLength(_ f: JSOpFormat) -> Int {
    switch f {
    case .none: return 1
    case .u8: return 2
    case .u16: return 3
    case .u32, .i32, .jump: return 5
    case .u32u32, .u32u32Const: return 9
    case .env: return 7
    case .envKey: return 11
    case .keyU8, .u8u32: return 6
    case .nullishJump: return 7
    case .table: return 3
    case .jump2: return 9
    }
}

/// throwError kinds.
public enum JSErrorKind: UInt8 {
    case error, typeError, rangeError, referenceError, syntaxError, evalError, uriError, aggregateError
}

/// Bits of a scope-info slot value (dynamic lookup).
enum JSScopeSlot {
    static let constFlag: Int32 = 1 << 24
    static let lexicalFlag: Int32 = 1 << 25
    static let indexMask: Int32 = (1 << 24) - 1
}

/// What a JSCode is.
enum JSCodeKind: UInt8 {
    case script, eval, function, arrow, method, getter, setter, classConstructor, derivedConstructor
    case fieldInit
}

/// defineMethod / defineMethodElem flags.
enum JSMethodFlags {
    static let enumerable: UInt8 = 1
    static let getter: UInt8 = 2
    static let setter: UInt8 = 4
    static let home: UInt8 = 8          // set the function's home object to the target
}

struct JSHandler {
    var start: UInt32
    var end: UInt32
    var target: UInt32
    var depth: UInt32
}

struct JSLineEntry {
    var pc: UInt32
    var offset: UInt32
}

/// A script's source, kept for stack-trace positions (shared by the codes
/// compiled from it; freed with the last one).
final class JSScriptSource {
    let name: String
    let lineMap: JSLineMap
    let bytes: [UInt8]
    init(name: String, source: [UInt8]) {
        self.name = name
        self.bytes = source
        self.lineMap = JSLineMap(source)
    }
}

/// One compiled function (or script / eval body).
final class JSCode {
    var bytes: [UInt8] = []
    /// A stable copy of `bytes` for the VM (made by finish()).
    private(set) var code: UnsafeMutablePointer<UInt8>
    private(set) var codeCount = 0
    var constants: [JSValue] = []
    var keys: [JSPropertyKey] = []
    var handlers: [JSHandler] = []
    var lines: [JSLineEntry] = []
    var kind: JSCodeKind = .function
    var strict = false
    var nparams = 0
    var nlocals = 0
    var maxStack = 0
    /// Local receiving the arguments object, or -1.
    var argumentsLocal = -1
    /// Local receiving the rest-parameter array, or -1.
    var restLocal = -1
    /// Function `length`.
    var length = 0
    /// The name (an atom string value, or the empty string).
    var name: JSValue = .string(0)
    /// Non-nil: calling this function throws "not supported yet: <stub>".
    var stub: String? = nil
    /// JSGenKind: 0 an ordinary function, else generator / async /
    /// async generator / module body (jsgenerator.swift).
    var genKind: UInt8 = 0
    /// Make an own `prototype` object for closures (ordinary functions).
    var hasPrototype = false
    var isConstructor = false
    var source: JSScriptSource? = nil
    /// Byte offsets of the function's source text (Function.prototype.toString).
    var sourceStart: UInt32 = 0
    var sourceEnd: UInt32 = 0
    /// The heap code object (kind .internalObject, user0) owning this code.
    var codeObject: JSValue = .undefined
    /// realm.codes index.
    var id = -1

    /// Stable copies of `constants` and `keys` for the VM (no ARC traffic).
    private(set) var constPtr: UnsafeMutablePointer<JSValue>
    private(set) var keyPtr: UnsafeMutablePointer<JSPropertyKey>

    init() {
        code = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        code.initialize(to: 0)
        constPtr = UnsafeMutablePointer<JSValue>.allocate(capacity: 1)
        constPtr.initialize(to: .undefined)
        keyPtr = UnsafeMutablePointer<JSPropertyKey>.allocate(capacity: 1)
        keyPtr.initialize(to: .index(0))
    }
    deinit {
        code.deallocate()
        constPtr.deallocate()
        keyPtr.deallocate()
    }

    func finish() {
        code.deallocate()
        let n = max(1, bytes.count)
        code = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        code.initialize(repeating: 0, count: n)
        for i in 0..<bytes.count { code[i] = bytes[i] }
        codeCount = bytes.count
        constPtr.deallocate()
        constPtr = UnsafeMutablePointer<JSValue>.allocate(capacity: max(1, constants.count))
        constPtr.initialize(repeating: .undefined, count: max(1, constants.count))
        for i in 0..<constants.count { constPtr[i] = constants[i] }
        keyPtr.deallocate()
        keyPtr = UnsafeMutablePointer<JSPropertyKey>.allocate(capacity: max(1, keys.count))
        keyPtr.initialize(repeating: .index(0), count: max(1, keys.count))
        for i in 0..<keys.count { keyPtr[i] = keys[i] }
    }

    func setConstant(_ i: Int, _ v: JSValue) {
        guard i >= 0 && i < constants.count else { return }
        constants[i] = v
        constPtr[i] = v
    }

    var isArrowLike: Bool { kind == .arrow }

    /// Source offset for a pc (the line entry at or before it).
    func offset(at pc: Int) -> Int {
        var lo = 0, hi = lines.count - 1
        if hi < 0 { return Int(sourceStart) }
        let p = UInt32(truncatingIfNeeded: max(0, pc))
        if lines[0].pc > p { return Int(lines[0].offset) }
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if lines[mid].pc <= p { lo = mid } else { hi = mid - 1 }
        }
        return Int(lines[lo].offset)
    }

    /// "name:line:column" for a pc.
    func location(at pc: Int) -> String {
        guard let s = source else { return "<native>" }
        let (l, c) = s.lineMap.location(offset(at: pc))
        return s.name + ":" + String(l) + ":" + String(c)
    }
}

// MARK: Decoding helpers

@inline(__always) func jsReadU16(_ p: UnsafePointer<UInt8>, _ i: Int) -> Int {
    Int(UnsafeRawPointer(p + i).loadUnaligned(as: UInt16.self).littleEndian)
}
@inline(__always) func jsReadU32(_ p: UnsafePointer<UInt8>, _ i: Int) -> Int {
    Int(UnsafeRawPointer(p + i).loadUnaligned(as: UInt32.self).littleEndian)
}
@inline(__always) func jsReadI32(_ p: UnsafePointer<UInt8>, _ i: Int) -> Int {
    Int(Int32(bitPattern: UnsafeRawPointer(p + i).loadUnaligned(as: UInt32.self).littleEndian))
}

func jsOpName(_ op: JSOp) -> String {
    switch op {
    case .nop: return "nop"
    case .pop: return "pop"
    case .popN: return "popN"
    case .dup: return "dup"
    case .dup2: return "dup2"
    case .swap: return "swap"
    case .rot3: return "rot3"
    case .rot4: return "rot4"
    case .over: return "over"
    case .pushUndefined: return "pushUndefined"
    case .pushNull: return "pushNull"
    case .pushTrue: return "pushTrue"
    case .pushFalse: return "pushFalse"
    case .pushHole: return "pushHole"
    case .pushInt: return "pushInt"
    case .pushConst: return "pushConst"
    case .getLocal: return "getLocal"
    case .putLocal: return "putLocal"
    case .setLocal: return "setLocal"
    case .getLocalChecked: return "getLocalChecked"
    case .putLocalChecked: return "putLocalChecked"
    case .getEnv: return "getEnv"
    case .putEnv: return "putEnv"
    case .setEnv: return "setEnv"
    case .getEnvChecked: return "getEnvChecked"
    case .putEnvChecked: return "putEnvChecked"
    case .pushEnv: return "pushEnv"
    case .popEnv: return "popEnv"
    case .cloneEnv: return "cloneEnv"
    case .saveEnv: return "saveEnv"
    case .restoreEnv: return "restoreEnv"
    case .enterWith: return "enterWith"
    case .getName: return "getName"
    case .getNameOrUndef: return "getNameOrUndef"
    case .putName: return "putName"
    case .getNameForCall: return "getNameForCall"
    case .deleteName: return "deleteName"
    case .getGlobal: return "getGlobal"
    case .getGlobalOrUndef: return "getGlobalOrUndef"
    case .putGlobal: return "putGlobal"
    case .getGlobalForCall: return "getGlobalForCall"
    case .declareVar: return "declareVar"
    case .declareFunc: return "declareFunc"
    case .declareLex: return "declareLex"
    case .initLex: return "initLex"
    case .getField: return "getField"
    case .putField: return "putField"
    case .getElem: return "getElem"
    case .putElem: return "putElem"
    case .getFieldForCall: return "getFieldForCall"
    case .getElemForCall: return "getElemForCall"
    case .deleteField: return "deleteField"
    case .deleteElem: return "deleteElem"
    case .getSuperField: return "getSuperField"
    case .getSuperElem: return "getSuperElem"
    case .putSuperField: return "putSuperField"
    case .putSuperElem: return "putSuperElem"
    case .newObject: return "newObject"
    case .newArray: return "newArray"
    case .defineField: return "defineField"
    case .defineElem: return "defineElem"
    case .defineMethod: return "defineMethod"
    case .defineMethodElem: return "defineMethodElem"
    case .appendElem: return "appendElem"
    case .appendHole: return "appendHole"
    case .appendSpread: return "appendSpread"
    case .copyDataProps: return "copyDataProps"
    case .objectRest: return "objectRest"
    case .setProto: return "setProto"
    case .closure: return "closure"
    case .newRegExp: return "newRegExp"
    case .templateObject: return "templateObject"
    case .newClass: return "newClass"
    case .setHomeObject: return "setHomeObject"
    case .setFieldInit: return "setFieldInit"
    case .add: return "add"
    case .sub: return "sub"
    case .mul: return "mul"
    case .div: return "div"
    case .mod: return "mod"
    case .exp: return "exp"
    case .shl: return "shl"
    case .sar: return "sar"
    case .shr: return "shr"
    case .bitAnd: return "bitAnd"
    case .bitOr: return "bitOr"
    case .bitXor: return "bitXor"
    case .lt: return "lt"
    case .gt: return "gt"
    case .le: return "le"
    case .ge: return "ge"
    case .eq: return "eq"
    case .ne: return "ne"
    case .strictEq: return "strictEq"
    case .strictNe: return "strictNe"
    case .instanceOf: return "instanceOf"
    case .inOp: return "in"
    case .neg: return "neg"
    case .plus: return "plus"
    case .not: return "not"
    case .bitNot: return "bitNot"
    case .typeOf: return "typeOf"
    case .inc: return "inc"
    case .dec: return "dec"
    case .toNumeric: return "toNumeric"
    case .toStringOp: return "toString"
    case .toPropertyKey: return "toPropertyKey"
    case .jump: return "jump"
    case .jumpIfTrue: return "jumpIfTrue"
    case .jumpIfFalse: return "jumpIfFalse"
    case .jumpIfTrueKeep: return "jumpIfTrueKeep"
    case .jumpIfFalseKeep: return "jumpIfFalseKeep"
    case .jumpIfNotNullishKeep: return "jumpIfNotNullishKeep"
    case .jumpIfNullish: return "jumpIfNullish"
    case .jumpIfUndefinedKeep: return "jumpIfUndefinedKeep"
    case .call: return "call"
    case .callArray: return "callArray"
    case .construct: return "construct"
    case .constructArray: return "constructArray"
    case .directEval: return "directEval"
    case .superCall: return "superCall"
    case .superCallArray: return "superCallArray"
    case .ret: return "ret"
    case .retUndefined: return "retUndefined"
    case .retDerived: return "retDerived"
    case .throwOp: return "throw"
    case .throwError: return "throwError"
    case .forInStart: return "forInStart"
    case .forInNext: return "forInNext"
    case .getIterator: return "getIterator"
    case .iterNext: return "iterNext"
    case .iterStepValue: return "iterStepValue"
    case .iterRest: return "iterRest"
    case .iterClose: return "iterClose"
    case .iterCloseThrow: return "iterCloseThrow"
    case .loadThis: return "loadThis"
    case .loadGlobalThis: return "loadGlobalThis"
    case .loadNewTarget: return "loadNewTarget"
    case .loadCallee: return "loadCallee"
    case .loadHomeObject: return "loadHomeObject"
    case .runFieldInit: return "runFieldInit"
    case .finallyDispatch: return "finallyDispatch"
    case .debugger: return "debugger"
    case .checkThisInit: return "checkThisInit"
    case .checkObjectCoercible: return "checkObjectCoercible"
    case .generatorStart: return "generatorStart"
    case .yield_: return "yield"
    case .yieldRaw: return "yieldRaw"
    case .asyncGenYield: return "asyncGenYield"
    case .await_: return "await"
    case .checkResume: return "checkResume"
    case .resumeIsReturn: return "resumeIsReturn"
    case .yieldStarCall: return "yieldStarCall"
    case .yieldStarResult: return "yieldStarResult"
    case .getAsyncIterator: return "getAsyncIterator"
    case .asyncIterResult: return "asyncIterResult"
    case .asyncReturnCall: return "asyncReturnCall"
    case .checkObject: return "checkObject"
    case .newPrivateName: return "newPrivateName"
    case .getPrivate: return "getPrivate"
    case .putPrivate: return "putPrivate"
    case .definePrivate: return "definePrivate"
    case .hasPrivate: return "hasPrivate"
    case .addPrivateBrand: return "addPrivateBrand"
    case .setPrivateMethod: return "setPrivateMethod"
    case .dup3: return "dup3"
    case .objectRestDynamic: return "objectRestDynamic"
    case .directEvalArray: return "directEvalArray"
    case .getterThisSwap: return "getterThisSwap"
    case .importMeta: return "importMeta"
    case .dynamicImport: return "dynamicImport"
    case .getModuleBinding: return "getModuleBinding"
    }
}

// MARK: Disassembler

/// A readable listing of `code` and (recursively, up to a depth) the
/// functions in its constant pool. `heap` renders constants.
func jsDisassemble(_ code: JSCode, heap: JSHeap, codes: (JSValue) -> JSCode?, depth: Int = 0) -> String {
    var out = ""
    let nm = heap.swiftString(code.name)
    out += "function \(nm.isEmpty ? "<anonymous>" : nm) params=\(code.nparams) locals=\(code.nlocals) stack=\(code.maxStack)"
    if code.strict { out += " strict" }
    if let s = code.stub { out += " stub(\(s))" }
    out += "\n"
    let p = UnsafePointer(code.code)
    let n = code.codeCount
    var pc = 0
    var nested: [JSCode] = []
    func key(_ i: Int) -> String {
        guard i >= 0 && i < code.keys.count else { return "?key" }
        let k = code.keys[i]
        if k.isIndex { return String(k.index) }
        if k.isSymbol { return "@sym" }
        return heap.swiftString(.string(k.handle))
    }
    func const_(_ i: Int) -> String {
        guard i >= 0 && i < code.constants.count else { return "?const" }
        let v = code.constants[i]
        if v.isNumber { return heap.swiftString(heap.numberToString(v.numberValue)) }
        if v.isString { return "\"" + heap.swiftString(v) + "\"" }
        if v.isObject, let c = codes(v) {
            if !nested.contains(where: { $0 === c }) { nested.append(c) }
            let cn = heap.swiftString(c.name)
            return "<code \(cn.isEmpty ? "anonymous" : cn)>"
        }
        if v.isObject { return "<object>" }
        if v.isUndefined { return "undefined" }
        return "?"
    }
    while pc < n {
        guard let op = JSOp(rawValue: p[pc]) else { out += "  \(pc): ??? \(p[pc])\n"; pc += 1; continue }
        let f = jsOpFormat(op)
        var len = jsFormatLength(f)
        if pc + len > n { out += "  \(pc): truncated\n"; break }
        var line = "  \(pc): \(jsOpName(op))"
        switch f {
        case .none: break
        case .u8: line += " \(p[pc + 1])"
        case .u16: line += " \(jsReadU16(p, pc + 1))"
        case .i32: line += " \(jsReadI32(p, pc + 1))"
        case .u32:
            let v = jsReadU32(p, pc + 1)
            switch op {
            case .pushConst, .closure, .templateObject, .pushEnv: line += " " + const_(v)
            case .getName, .getNameOrUndef, .putName, .getNameForCall, .deleteName, .getGlobal, .getGlobalOrUndef,
                 .putGlobal, .getGlobalForCall, .declareVar, .declareFunc, .initLex, .getField, .putField,
                 .getFieldForCall, .deleteField, .getSuperField, .putSuperField, .defineField:
                line += " " + key(v)
            default: line += " \(v)"
            }
        case .jump: line += " -> \(pc + len + jsReadI32(p, pc + 1))"
        case .jump2: line += " -> \(pc + len + jsReadI32(p, pc + 1)), \(pc + len + jsReadI32(p, pc + 5))"
        case .u32u32: line += " \(jsReadU32(p, pc + 1)) " + key(jsReadU32(p, pc + 5))
        case .u32u32Const: line += " " + const_(jsReadU32(p, pc + 1)) + " " + const_(jsReadU32(p, pc + 5))
        case .env: line += " \(jsReadU16(p, pc + 1)):\(jsReadU32(p, pc + 3))"
        case .envKey: line += " \(jsReadU16(p, pc + 1)):\(jsReadU32(p, pc + 3)) " + key(jsReadU32(p, pc + 7))
        case .keyU8:
            let a = jsReadU32(p, pc + 1)
            line += " " + (op == .newClass || op == .newPrivateName ? const_(a) : key(a)) + " \(p[pc + 5])"
        case .u8u32: line += " \(p[pc + 1]) " + const_(jsReadU32(p, pc + 2))
        case .nullishJump:
            line += " -> \(pc + len + jsReadI32(p, pc + 1)) at \(p[pc + 5]) pop \(p[pc + 6])"
        case .table:
            let cnt = jsReadU16(p, pc + 1)
            len = 3 + 4 * cnt
            if pc + len > n { out += line + " truncated\n"; pc = n; continue }
            var targets: [String] = []
            for i in 0..<cnt { targets.append(String(pc + len + jsReadI32(p, pc + 3 + 4 * i))) }
            line += " [" + targets.joined(separator: ", ") + "]"
        }
        out += line + "\n"
        pc += len
    }
    for h in code.handlers {
        out += "  handler \(h.start)..<\(h.end) -> \(h.target) depth \(h.depth)\n"
    }
    if depth < 8 {
        for c in nested { out += jsDisassemble(c, heap: heap, codes: codes, depth: depth + 1) }
    }
    return out
}
