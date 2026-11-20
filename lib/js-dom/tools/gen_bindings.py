#!/usr/bin/env python3
"""DOM binding generator (ROADMAP Phase 9G, "Bindings are generated").

Reads lib/js-dom/idl/*.txt (a WebIDL subset, see below) and writes
lib/js-dom/jsdom_generated.swift: the Swift glue between lib/js and the
hand-written DOM implementation (jsdom_*.swift). The glue does argument
conversion per WebIDL, `this` checks (TypeError "Illegal invocation"),
getters, setters, constants, interface objects, prototype chains and
dictionaries; the implementation only sees Swift values.

    python3 lib/js-dom/tools/gen_bindings.py           # regenerate
    python3 lib/js-dom/tools/gen_bindings.py --check   # exit 1 if stale

The host test (lib/js-dom/tests) runs --check, so the checked-in output
always matches the IDL.

IDL subset
----------
Definitions (one or more per file):

    [ExtAttrs] interface Name : Parent { members };
    interface mixin Name { members };
    Name includes Mixin;
    dictionary Name : Parent { [required] Type name = default; ... };
    callback Name = Return (args);      callback interface Name { ... };
    typedef Type Name;                  enum Name { "a", "b" };
    namespace Name { operations };

Members: `const T N = v;`, `[readonly] attribute T name;`,
`[static] T name(args);`, `constructor(args);`, `iterable<T>;`,
`stringifier;` / `stringifier attribute ...`, and `getter`/`setter`/
`deleter` prefixes (markers only: the indexed/named behavior is supplied
by the implementation's JSHostExotic). Arguments may be `optional`, have
defaults, be nullable (`T?`) or variadic (`T... name`).

Interface extended attributes:
  Kind=node|event|target|anytarget|window|object   how `this` is unwrapped
        node: HTMLNode (one identity cache, prototype per interface);
        event: JSDOMEvent; target: JSDOMEventTargetObject; anytarget:
        JSDOMTarget (EventTarget); window: the page (JSDOMBindings);
        object: the Swift class in Swift=, with its own JSHostClass.
        Inherited from the parent when absent.
  Swift=Type          object kinds: the Swift class.
  Exotic              object kinds: the class gets `b.exotic_<Name>()`.
  Tags=a|b|c          HTML (or SVG) elements with these local names get
                      this interface (node kinds).
  SVGTags=svg|g       the same for SVG elements.
  Global              Window: members go on the global object itself.
  LegacyNoInterfaceObject  no global constructor.
  LegacyFactoryFunction=Image   an extra named constructor (impl:
                      b.<Name>_factory(args, newTarget:)).

Member extended attributes:
  Throws              the implementation function throws(JSThrow).
  CEReactions         marks DOM APIs that can run custom element
                      reactions (9I wraps these); recorded in the
                      generated table jsdomCEReactionMembers.
  Reflect / Reflect=name   reflected content attribute (DOMString,
                      boolean, long, unsigned long); no implementation
                      function needed. With URL: the value is resolved
                      against the document's base URL.
  Default=v           Reflect of a number: the value when absent/invalid.
  SameObject          the result is cached on the wrapper (a hidden slot).
  PutForwards=name    assignment sets `name` on the attribute's object.
  Replaceable         assignment shadows the attribute with a data property.
  LegacyNullToEmptyString   null converts to "".
  Impl=name           implementation function name override.

Implementation contract (see jsdom_bindings.swift): for interface I and
member m, the generated code calls on JSDOMBindings
  attribute getter    I_m(this) -> T
  attribute setter    I_set_m(this, value)
  operation           I_m(this, args...) -> T
  static operation    I_static_m(args...) -> T
  constructor         I_constructor(args..., newTarget: JSValue) -> JSValue
  namespace operation I_m(args...) -> T
with Swift types: DOMString -> String (String? if nullable), boolean ->
Bool, integer types -> Int, double/float -> Double, node interfaces ->
HTMLNode, Event types -> JSDOMEvent, EventTarget -> JSDOMTarget, object
interfaces -> their Swift class, dictionaries -> JSDOM_<Name> structs,
sequence<T> -> [T], unions/any/object/callbacks/Promise -> JSValue;
optional arguments without a default -> T?. Returned node interfaces are
HTMLNode? (wrapped, null for nil), returned objects other than nodes and
primitives are JSValue (the implementation wraps them).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IDL_DIR = os.path.join(ROOT, "idl")
OUT = os.path.join(ROOT, "jsdom_generated.swift")

INT_TYPES = {
    "byte": "toByte", "octet": "toOctet", "short": "toShort", "unsigned short": "toUnsignedShort",
    "long": "toLong", "unsigned long": "toUnsignedLong", "long long": "toLongLong",
    "unsigned long long": "toUnsignedLongLong",
}
FLOAT_TYPES = {"double", "float"}
UFLOAT_TYPES = {"unrestricted double", "unrestricted float"}
STRING_TYPES = {"DOMString", "USVString", "ByteString", "CSSOMString"}


class IDLError(Exception):
    pass


# ---------------------------------------------------------------- lexer

TOKEN_RE = re.compile(r"""
    (?P<ws>\s+|//[^\n]*|/\*.*?\*/|\#[^\n]*)
  | (?P<str>"[^"]*")
  | (?P<num>-?(?:0x[0-9A-Fa-f]+|[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?))
  | (?P<id>[A-Za-z_][A-Za-z0-9_\-]*)
  | (?P<ell>\.\.\.)
  | (?P<p>[{}()\[\];:,=<>?|])
""", re.S | re.X)


SWIFT_KEYWORDS = {"is", "repeat", "default", "in", "as", "where", "case", "for", "if", "do", "else", "switch",
                  "return", "class", "struct", "import", "static", "self", "Self", "true", "false", "nil", "var",
                  "let", "func", "init", "inout", "operator", "protocol", "extension", "enum", "break",
                  "continue", "while", "throw", "throws", "try", "catch", "defer", "guard", "super", "Type"}


def sid(name):
    """A Swift identifier for an IDL name (keywords in backticks)."""
    return "`%s`" % name if name in SWIFT_KEYWORDS else name


def lex(text, fname):
    toks = []
    i = 0
    while i < len(text):
        m = TOKEN_RE.match(text, i)
        if not m:
            raise IDLError("%s: bad character %r" % (fname, text[i]))
        i = m.end()
        k = m.lastgroup
        if k == "ws":
            continue
        toks.append((k, m.group(k)))
    return toks


class Parser:
    def __init__(self, toks, fname):
        self.t = toks
        self.i = 0
        self.f = fname

    def peek(self, k=0):
        j = self.i + k
        return self.t[j][1] if j < len(self.t) else None

    def next(self):
        if self.i >= len(self.t):
            raise IDLError(self.f + ": unexpected end")
        v = self.t[self.i][1]
        self.i += 1
        return v

    def expect(self, v):
        got = self.next()
        if got != v:
            raise IDLError("%s: expected %r, got %r (token %d)" % (self.f, v, got, self.i))

    def ext_attrs(self):
        attrs = {}
        if self.peek() != "[":
            return attrs
        self.next()
        while True:
            name = self.next()
            val = True
            if self.peek() == "=":
                self.next()
                if self.peek() == "(":
                    self.next()
                    parts = []
                    while self.peek() != ")":
                        parts.append(self.next())
                    self.next()
                    val = "".join(parts)
                else:
                    parts = [self.next()]
                    while self.peek() == "|":
                        self.next()
                        parts.append(self.next())
                    val = "|".join(parts)
                    # LegacyFactoryFunction=Image(args)
                    if self.peek() == "(":
                        depth = 0
                        while True:
                            x = self.next()
                            if x == "(":
                                depth += 1
                            elif x == ")":
                                depth -= 1
                                if depth == 0:
                                    break
            attrs[name] = val
            if self.peek() == ",":
                self.next()
                continue
            self.expect("]")
            return attrs

    def type(self):
        if self.peek() == "(":
            self.next()
            members = [self.type()]
            while self.peek() == "or":
                self.next()
                members.append(self.type())
            self.expect(")")
            t = {"kind": "union", "members": members, "nullable": False}
        else:
            words = [self.next()]
            if words[0] in ("unsigned", "unrestricted"):
                words.append(self.next())
            if words[-1] == "long" and self.peek() == "long":
                words.append(self.next())
            name = " ".join(words)
            t = {"kind": "named", "name": name, "nullable": False}
            if name in ("sequence", "FrozenArray", "Promise", "record") and self.peek() == "<":
                self.next()
                inner = [self.type()]
                while self.peek() == ",":
                    self.next()
                    inner.append(self.type())
                self.expect(">")
                t = {"kind": name, "inner": inner, "nullable": False}
        if self.peek() == "?":
            self.next()
            t["nullable"] = True
        return t

    def default_value(self):
        v = self.next()
        if v == "{":
            self.expect("}")
            return "{}"
        if v == "[":
            self.expect("]")
            return "[]"
        return v

    def args(self):
        self.expect("(")
        out = []
        while self.peek() != ")":
            ea = self.ext_attrs()
            optional = False
            if self.peek() == "optional":
                self.next()
                optional = True
            t = self.type()
            variadic = False
            if self.peek() == "...":
                self.next()
                variadic = True
            name = self.next()
            default = None
            if self.peek() == "=":
                self.next()
                default = self.default_value()
            out.append({"name": name, "type": t, "optional": optional, "variadic": variadic,
                        "default": default, "ext": ea})
            if self.peek() == ",":
                self.next()
        self.expect(")")
        return out

    def members(self, is_dict=False):
        self.expect("{")
        out = []
        while self.peek() != "}":
            ea = self.ext_attrs()
            if is_dict:
                required = False
                if self.peek() == "required":
                    self.next()
                    required = True
                t = self.type()
                name = self.next()
                default = None
                if self.peek() == "=":
                    self.next()
                    default = self.default_value()
                self.expect(";")
                out.append({"kind": "field", "name": name, "type": t, "default": default,
                            "required": required, "ext": ea})
                continue
            w = self.peek()
            if w == "const":
                self.next()
                t = self.type()
                name = self.next()
                self.expect("=")
                v = self.next()
                self.expect(";")
                out.append({"kind": "const", "name": name, "type": t, "value": v, "ext": ea})
                continue
            if w == "constructor":
                self.next()
                a = self.args()
                self.expect(";")
                out.append({"kind": "constructor", "args": a, "ext": ea})
                continue
            if w == "iterable":
                self.next()
                self.expect("<")
                t = self.type()
                self.expect(">")
                self.expect(";")
                out.append({"kind": "iterable", "type": t, "ext": ea})
                continue
            static = stringifier = readonly = False
            special = None
            while True:
                w = self.peek()
                if w == "static":
                    static = True
                elif w == "stringifier":
                    stringifier = True
                elif w == "readonly":
                    readonly = True
                elif w in ("getter", "setter", "deleter"):
                    special = w
                else:
                    break
                self.next()
            if stringifier and self.peek() == ";":
                self.next()
                out.append({"kind": "stringifier", "ext": ea})
                continue
            if self.peek() == "attribute":
                self.next()
                t = self.type()
                name = self.next()
                self.expect(";")
                out.append({"kind": "attribute", "name": name, "type": t, "readonly": readonly,
                            "static": static, "stringifier": stringifier, "ext": ea})
                continue
            rt = self.type()
            name = self.next()
            a = self.args()
            self.expect(";")
            out.append({"kind": "operation", "name": name, "ret": rt, "args": a, "static": static,
                        "special": special, "stringifier": stringifier, "ext": ea})
        self.expect("}")
        self.expect(";")
        return out


def parse_all():
    defs = {"interfaces": {}, "mixins": {}, "includes": [], "dicts": {}, "callbacks": {},
            "callback_interfaces": {}, "typedefs": {}, "enums": {}, "namespaces": {}}
    order = []
    files = sorted(f for f in os.listdir(IDL_DIR) if f.endswith(".txt"))
    for fname in files:
        with open(os.path.join(IDL_DIR, fname)) as fh:
            text = fh.read()
        p = Parser(lex(text, fname), fname)
        while p.peek() is not None:
            ea = p.ext_attrs()
            w = p.next()
            if w == "interface":
                if p.peek() == "mixin":
                    p.next()
                    name = p.next()
                    defs["mixins"][name] = {"name": name, "members": p.members(), "ext": ea}
                    continue
                name = p.next()
                parent = None
                if p.peek() == ":":
                    p.next()
                    parent = p.next()
                if name in defs["interfaces"]:
                    raise IDLError("duplicate interface " + name)
                defs["interfaces"][name] = {"name": name, "parent": parent, "members": p.members(),
                                            "ext": ea, "file": fname}
                order.append(name)
            elif w == "dictionary":
                name = p.next()
                parent = None
                if p.peek() == ":":
                    p.next()
                    parent = p.next()
                defs["dicts"][name] = {"name": name, "parent": parent, "members": p.members(True)}
            elif w == "callback":
                if p.peek() == "interface":
                    p.next()
                    name = p.next()
                    defs["callback_interfaces"][name] = p.members()
                    continue
                name = p.next()
                p.expect("=")
                rt = p.type()
                a = p.args()
                p.expect(";")
                defs["callbacks"][name] = {"ret": rt, "args": a}
            elif w == "typedef":
                t = p.type()
                name = p.next()
                p.expect(";")
                defs["typedefs"][name] = t
            elif w == "enum":
                name = p.next()
                p.expect("{")
                vals = []
                while p.peek() != "}":
                    v = p.next()
                    if v != ",":
                        vals.append(v.strip('"'))
                p.expect("}")
                p.expect(";")
                defs["enums"][name] = vals
            elif w == "namespace":
                name = p.next()
                defs["namespaces"][name] = {"name": name, "members": p.members(), "ext": ea}
            else:
                # Name includes Mixin;
                target = w
                p.expect("includes")
                mixin = p.next()
                p.expect(";")
                defs["includes"].append((target, mixin, ea))
    defs["order"] = order
    return defs, files


# ------------------------------------------------------------ generator

class Gen:
    def __init__(self, defs):
        self.d = defs
        self.ifaces = defs["interfaces"]
        self.out = []
        self.same_object_slots = {}
        self.ce_members = []
        self.signatures = {}
        # Topological order: parents first, then file order.
        self.topo = []
        seen = set()

        def visit(n):
            if n in seen:
                return
            p = self.ifaces[n]["parent"]
            if p:
                if p not in self.ifaces:
                    raise IDLError("%s: unknown parent %s" % (n, p))
                visit(p)
            seen.add(n)
            self.topo.append(n)
        for n in defs["order"]:
            visit(n)
        self.index = {n: i for i, n in enumerate(self.topo)}
        # Mixins into interfaces.
        for target, mixin, ea in defs["includes"]:
            if target not in self.ifaces or mixin not in defs["mixins"]:
                raise IDLError("bad includes %s %s" % (target, mixin))
            m = defs["mixins"][mixin]
            for mem in m["members"]:
                mm = dict(mem)
                mm["mixin"] = mixin
                mm["includeExt"] = ea
                self.ifaces[target]["members"].append(mm)

    def w(self, s=""):
        self.out.append(s)

    def kind(self, n):
        while n:
            i = self.ifaces[n]
            if "Kind" in i["ext"]:
                return i["ext"]["Kind"]
            n = i["parent"]
        return "object"

    def swift_class(self, n):
        i = self.ifaces[n]
        if "Swift" in i["ext"]:
            return i["ext"]["Swift"]
        return {"node": "HTMLNode", "event": "JSDOMEvent", "target": "JSDOMEventTargetObject",
                "anytarget": "JSDOMTarget", "window": "JSDOMBindings"}.get(self.kind(n), n)

    def resolve(self, t):
        """Follow typedefs; returns a type dict."""
        seen = 0
        while t["kind"] == "named" and t["name"] in self.d["typedefs"] and seen < 20:
            nt = dict(self.d["typedefs"][t["name"]])
            nt["nullable"] = nt["nullable"] or t["nullable"]
            nt["typedefName"] = t["name"]
            t = nt
            seen += 1
        return t

    # --- types

    def category(self, t):
        t = self.resolve(t)
        k = t["kind"]
        if k == "union":
            return "raw"
        if k in ("Promise", "record", "FrozenArray"):
            return "raw"
        if k == "sequence":
            return "sequence"
        n = t["name"]
        if n in ("any", "object"):
            return n
        if n == "undefined":
            return "undefined"
        if n == "boolean":
            return "bool"
        if n in STRING_TYPES or n in self.d["enums"]:
            return "string"
        if n in INT_TYPES:
            return "int"
        if n in FLOAT_TYPES:
            return "double"
        if n in UFLOAT_TYPES:
            return "udouble"
        if n in self.d["dicts"]:
            return "dict"
        if n in self.d["callbacks"]:
            return "callback"
        if n in self.d["callback_interfaces"]:
            return "callbackInterface"
        if n == "EventHandler" or t.get("typedefName") == "EventHandler":
            return "handler"
        if n in self.ifaces:
            k2 = self.kind(n)
            if k2 == "node":
                return "node"
            if k2 == "event":
                return "event"
            if k2 == "anytarget":
                return "target"
            if k2 == "window":
                return "raw"
            return "obj"
        if n in ("WindowProxy",):
            return "raw"
        raise IDLError("unknown type " + n)

    def swift_type(self, t, arg=True):
        c = self.category(t)
        t = self.resolve(t)
        base = {
            "bool": "Bool", "string": "String", "int": "Int", "double": "Double", "udouble": "Double",
            "any": "JSValue", "object": "JSValue", "raw": "JSValue", "callback": "JSValue",
            "callbackInterface": "JSValue", "handler": "JSValue", "undefined": "Void",
            "node": "HTMLNode", "event": "JSDOMEvent", "target": "JSDOMTarget",
        }.get(c)
        if c == "obj":
            base = self.swift_class(t["name"])
        if c == "dict":
            base = "JSDOM_" + t["name"]
        if c == "sequence":
            base = "[" + self.swift_type(t["inner"][0]) + "]"
        if t["nullable"] and c not in ("any", "raw", "callback", "callbackInterface", "handler", "object"):
            base += "?"
        return base

    def convert(self, t, v, ctx, ext=None):
        """Swift expression converting JSValue `v` to the argument type."""
        ext = ext or {}
        c = self.category(t)
        t = self.resolve(t)
        nul = t["nullable"]
        if c == "bool":
            e = "b.heap.toBoolean(%s)" % v
        elif c == "string":
            if "LegacyNullToEmptyString" in ext:
                e = "try b.toStrNullEmpty(%s)" % v
            else:
                e = "try b.toStr(%s)" % v
            if t["kind"] == "named" and t["name"] in self.d["enums"]:
                vals = ", ".join('"%s"' % x for x in self.d["enums"][t["name"]])
                e = "try b.toEnum(%s, [%s], %s)" % (v, vals, ctx)
        elif c == "int":
            e = "try b.%s(%s)" % (INT_TYPES[t["name"]], v)
        elif c == "double":
            e = "try b.toDouble(%s, %s)" % (v, ctx)
        elif c == "udouble":
            e = "try b.realm.toNumber(%s)" % v
        elif c in ("any", "raw"):
            return v
        elif c == "object":
            return "try b.toObjectArg(%s, nullable: %s, %s)" % (v, "true" if nul else "false", ctx)
        elif c == "callback":
            return "try b.toCallbackFunction(%s, nullable: %s, %s)" % (v, "true" if nul else "false", ctx)
        elif c == "callbackInterface":
            return "try b.toCallbackInterface(%s, nullable: %s, %s)" % (v, "true" if nul else "false", ctx)
        elif c == "handler":
            return v
        elif c == "node":
            if nul:
                return "try b.toNodeOrNull(%s, .%s, %s)" % (v, t["name"], ctx)
            return "try b.toNode(%s, .%s, %s)" % (v, t["name"], ctx)
        elif c == "event":
            if nul:
                return "(%s.isNullish ? nil : try b.toEvent(%s, .%s, %s))" % (v, v, t["name"], ctx)
            return "try b.toEvent(%s, .%s, %s)" % (v, t["name"], ctx)
        elif c == "target":
            if nul:
                return "(%s.isNullish ? nil : try b.toTarget(%s, %s))" % (v, v, ctx)
            return "try b.toTarget(%s, %s)" % (v, ctx)
        elif c == "obj":
            cls = "b.classes.%s" % self.class_owner(t["name"])
            if self.kind(t["name"]) == "target":
                cls = "b.classes.EventTargetObject"
                if nul:
                    return "(%s.isNullish ? nil : try b.toTargetObject(%s, .%s, %s))" % (v, v, t["name"], ctx)
                return "try b.toTargetObject(%s, .%s, %s)" % (v, t["name"], ctx)
            if nul:
                return "(%s.isNullish ? nil : try b.toObj(%s, %s, %s))" % (v, cls, v, ctx)
            return "try b.toObj(%s, %s, %s)" % (cls, v, ctx)
        elif c == "dict":
            return "try b.dict_%s(%s)" % (t["name"], v)
        elif c == "sequence":
            inner = self.convert(t["inner"][0], "e", ctx)
            st = self.swift_type(t["inner"][0])
            e = "try b.toSequence(%s, %s) { (e: JSValue) throws(JSThrow) -> %s in %s }" % (v, ctx, st, inner)
        else:
            raise IDLError("cannot convert " + str(t))
        if nul:
            return "(%s.isNullish ? nil : %s)" % (v, e)
        return e

    def class_owner(self, n):
        return n

    def ret(self, t, expr):
        """Swift statements returning `expr` (the impl call) as a JSValue."""
        c = self.category(t)
        t = self.resolve(t)
        nul = t["nullable"]
        if c == "undefined":
            return "%s\n            return .undefined" % expr
        if c == "bool":
            return "return .bool(%s)" % expr
        if c == "string":
            return "return %s(%s)" % ("b.strOrNull" if nul else "b.str", expr)
        if c in ("int", "double", "udouble"):
            return "return %s(%s)" % ("b.numOrNull" if nul else "JSValue.number", expr)
        if c == "node":
            return "return b.wrapNode(%s)" % expr
        if c == "event":
            return "return b.wrapEvent(%s)" % expr
        if c == "target":
            return "return b.wrapTarget(%s)" % expr
        return "return %s" % expr

    # --- helpers

    def unwrap(self, n):
        k = self.kind(n)
        if k == "node":
            return "b.thisNode(args.this, .%s)" % n
        if k == "event":
            return "b.thisEvent(args.this, .%s)" % n
        if k == "target":
            return "b.thisTargetObject(args.this, .%s)" % n
        if k == "anytarget":
            return "b.thisTarget(args.this)"
        if k == "window":
            return "b.thisWindow(args.this)"
        return "b.classes.%s.unwrap(args.this)" % n

    def target_expr(self, n):
        k = self.kind(n)
        if k == "node":
            return "JSDOMTarget.node(this)"
        if k == "window":
            return "JSDOMTarget.window"
        if k == "target":
            return "JSDOMTarget.object(this)"
        if k == "anytarget":
            return "this"
        raise IDLError("EventHandler on non-target " + n)

    def sig(self, name, this_iface, params, ret, throws):
        """Record the Swift signature an implementation function must have."""
        ps = []
        if this_iface:
            ps.append("_ this: " + self.swift_class(this_iface))
        for i, (t, opt) in enumerate(params):
            ps.append("_ a%d: %s%s" % (i, t, "?" if opt else ""))
        r = "" if ret in ("Void",) else " -> " + ret
        th = " throws(JSThrow)" if throws else ""
        self.signatures.setdefault(name, "func %s(%s)%s%s" % (name, ", ".join(ps), th, r))

    def ret_type(self, t):
        c = self.category(t)
        if c == "undefined":
            return "Void"
        if c in ("node", "event", "target"):
            return self.swift_type(t).rstrip("?") + "?" if c == "node" or self.resolve(t)["nullable"] else self.swift_type(t)
        if c in ("obj", "dict", "sequence"):
            return "JSValue"
        return self.swift_type(t)

    def arg_sig(self, a):
        st = self.swift_type(a["type"])
        if a["variadic"]:
            return ("[" + st + "]", False)
        opt = a["optional"] and a["default"] is None and self.category(a["type"]) not in ("any", "raw", "dict")
        return (st, opt)

    def impl_name(self, iface, mem, prefix=""):
        if "Impl" in mem["ext"]:
            impl = mem["ext"]["Impl"]
            if prefix and "_" in impl:
                owner, rest = impl.split("_", 1)
                return owner + "_" + prefix + rest
            return impl
        owner = mem.get("mixin", iface)
        return owner + "_" + prefix + mem["name"]

    def gen_args(self, iface, opname, args, ind):
        """Emit conversions; returns the list of Swift argument expressions."""
        exprs = []
        required = 0
        for a in args:
            if not a["optional"] and not a["variadic"]:
                required += 1
        ctx = '"%s", "%s"' % (iface, opname)
        lines = []
        if required:
            lines.append("if args.count < %d { throw b.notEnoughArguments(%s, %d, args.count) }" % (required, ctx, required))
        for i, a in enumerate(args):
            var = "a%d" % i
            st = self.swift_type(a["type"])
            ctxa = "b.ctx(%s)" % ctx
            if a["variadic"]:
                conv = self.convert(a["type"], "args[k]", ctxa, a["ext"])
                lines.append("var %s: [%s] = []" % (var, st))
                lines.append("var k = %d" % i)
                lines.append("while k < args.count { %s.append(%s); k += 1 }" % (var, conv))
            elif a["optional"] and a["default"] is None and self.category(a["type"]) not in ("any", "raw", "dict"):
                conv = self.convert(a["type"], "args[%d]" % i, ctxa, a["ext"])
                lines.append("let %s: %s? = args[%d].isUndefined ? nil : %s" % (var, st, i, conv))
            elif a["optional"] and self.category(a["type"]) == "dict":
                lines.append("let %s = %s" % (var, self.convert(a["type"], "args[%d]" % i, ctxa)))
            elif a["optional"] and a["default"] is not None and self.category(a["type"]) not in ("any", "raw"):
                conv = self.convert(a["type"], "args[%d]" % i, ctxa, a["ext"])
                dv = self.swift_default(a["type"], a["default"])
                lines.append("let %s: %s = args[%d].isUndefined ? %s : %s" % (var, st, i, dv, conv))
            else:
                conv = self.convert(a["type"], "args[%d]" % i, ctxa, a["ext"])
                lines.append("let %s: %s = %s" % (var, st, conv))
            exprs.append(var)
        for l in lines:
            self.w(ind + l)
        return exprs

    def swift_default(self, t, d):
        c = self.category(t)
        if d == "null":
            return "nil"
        if c == "bool":
            return d
        if c == "string":
            return d
        if c in ("int", "double", "udouble"):
            return d
        if d == "[]":
            return "[]"
        raise IDLError("default %s for %s" % (d, t))

    def same_slot(self, iface, name):
        key = iface + "." + name
        if key not in self.same_object_slots:
            self.same_object_slots[key] = len(self.same_object_slots)
        return self.same_object_slots[key]

    # --- emit

    def emit(self, files):
        w = self.w
        w("// Generated by lib/js-dom/tools/gen_bindings.py from lib/js-dom/idl/*.txt.")
        w("// Do not edit: change the IDL (or the generator) and rerun it.")
        w("// Inputs: " + " ".join(files))
        w("")
        w("/// Every generated interface, parents before children.")
        w("enum JSDOMInterface: Int {")
        for n in self.topo:
            w("    case %s" % n)
        w("    case count")
        w("}")
        w("")
        w("/// Parent interface (raw value), -1 for a root.")
        w("let jsdomInterfaceParents: [Int] = [")
        for n in self.topo:
            p = self.ifaces[n]["parent"]
            w("    %d,  // %s" % (self.index[p] if p else -1, n))
        w("]")
        w("")
        w("let jsdomInterfaceNames: [String] = [")
        for n in self.topo:
            w('    "%s",' % n)
        w("]")
        w("")
        # Tags
        for attr, fn in (("Tags", "jsdomHTMLInterface"), ("SVGTags", "jsdomSVGInterface")):
            w("/// The interface for an element by local name (nil: the default).")
            w("func %s(_ localName: String) -> JSDOMInterface? {" % fn)
            w("    switch localName {")
            for n in self.topo:
                tags = self.ifaces[n]["ext"].get(attr)
                if tags:
                    w("    case %s: return .%s" % (", ".join('"%s"' % x for x in tags.split("|")), n))
            w("    default: return nil")
            w("    }")
            w("}")
            w("")
        # Dictionaries
        self.emit_dicts()
        # Classes for object kinds.
        objs = [n for n in self.topo if self.kind(n) == "object"]
        w("/// Host classes for the object-kind interfaces (one identity cache each).")
        w("final class JSDOMClasses {")
        for n in objs:
            w("    let %s: JSHostClass<%s>" % (n, self.swift_class(n)))
        w("    let EventTargetObject: JSHostClass<JSDOMEventTargetObject>")
        w("")
        w("    init(_ b: JSDOMBindings) {")
        w("        let realm = b.realm")
        for n in objs:
            i = self.ifaces[n]
            parent = "b.protos[%d]" % self.index[i["parent"]] if i["parent"] else "nil"
            exo = ", exotic: b.exotic_%s()" % n if "Exotic" in i["ext"] else ""
            w('        %s = JSHostClass<%s>(realm: realm, name: "%s", parent: %s%s)' % (n, self.swift_class(n), n, parent, exo))
            w("        b.protos[%d] = %s.prototype" % (self.index[n], n))
        w('        EventTargetObject = JSHostClass<JSDOMEventTargetObject>(realm: realm, name: "EventTarget", parent: b.protos[%d])' % self.index["EventTarget"])
        w("    }")
        w("}")
        w("")
        w("extension JSDOMBindings {")
        w("    /// Prototype objects for the non-object kinds, parents first (object")
        w("    /// kinds get theirs from JSDOMClasses).")
        w("    func makeGeneratedPrototypes() {")
        for n in self.topo:
            if self.kind(n) == "object":
                continue
            p = self.ifaces[n]["parent"]
            w("        makePrototype(.%s, parent: %s)" % (n, (".%s" % p) if p else "nil"))
        w("    }")
        w("")
        w("    func makeGeneratedClasses() {")
        for n in objs:
            p = self.ifaces[n]["parent"]
            if p and self.kind(p) == "object":
                pass
        w("        classes = JSDOMClasses(self)")
        w("    }")
        w("")
        w("    func installGenerated() {")
        for n in self.topo:
            w("        gen_%s()" % n)
        for n in self.d["namespaces"]:
            w("        gen_ns_%s()" % n)
        w("    }")
        w("}")
        w("")
        for n in self.topo:
            self.emit_interface(n)
        for n, ns in self.d["namespaces"].items():
            self.emit_namespace(n, ns)
        w("/// Members marked [CEReactions] (\"Interface.member\"), for 9I.")
        w("let jsdomCEReactionMembers: [String] = [")
        for m in self.ce_members:
            w('    "%s",' % m)
        w("]")
        w("")
        w("/// Number of [SameObject] cache slots a wrapper may need.")
        w("let jsdomSameObjectSlotCount = %d" % len(self.same_object_slots))
        return "\n".join(self.out) + "\n"

    def dict_fields(self, name):
        d = self.d["dicts"][name]
        fields = []
        if d["parent"]:
            fields.extend(self.dict_fields(d["parent"]))
        fields.extend(sorted(d["members"], key=lambda m: m["name"]))
        return fields

    def emit_dicts(self):
        w = self.w
        for name in sorted(self.d["dicts"]):
            fields = self.dict_fields(name)
            w("struct JSDOM_%s {" % name)
            for f in fields:
                st = self.swift_type(f["type"])
                c = self.category(f["type"])
                if f["default"] is not None and c not in ("any", "raw", "callback", "callbackInterface", "object"):
                    dv = self.swift_default(f["type"], f["default"])
                    w("    var %s: %s = %s" % (sid(f["name"]), st, dv))
                elif c in ("any", "raw", "callback", "callbackInterface", "object", "handler"):
                    dv = ".null" if f["default"] == "null" else ".undefined"
                    w("    var %s: JSValue = %s" % (sid(f["name"]), dv))
                else:
                    if not st.endswith("?"):
                        st += "?"
                    w("    var %s: %s = nil" % (sid(f["name"]), st))
            w("    /// Members that were present in the dictionary.")
            w("    var present: Set<String> = []")
            w("    init() {}")
            w("}")
            w("")
        w("extension JSDOMBindings {")
        for name in sorted(self.d["dicts"]):
            fields = self.dict_fields(name)
            w("    func dict_%s(_ v: JSValue) throws(JSThrow) -> JSDOM_%s {" % (name, name))
            w("        var d = JSDOM_%s()" % name)
            w("        if v.isNullish { return d }")
            w('        if !v.isObject { throw realm.throwTypeError("%s: not an object") }' % name)
            w("        let b = self")
            for f in fields:
                w('        let v_%s = try realm.getV(v, heap.key("%s"))' % (f["name"], f["name"]))
                c = self.category(f["type"])
                conv = self.convert(f["type"], "v_" + f["name"], 'b.ctx("%s", "%s")' % (name, f["name"]))
                if c in ("any", "raw", "callback", "callbackInterface", "object", "handler"):
                    w("        if !v_%s.isUndefined { _ = heap.root(v_%s); d.%s = %s; d.present.insert(\"%s\") }" % (
                        f["name"], f["name"], sid(f["name"]), conv, f["name"]))
                else:
                    w("        if !v_%s.isUndefined { d.%s = %s; d.present.insert(\"%s\") }" % (
                        f["name"], sid(f["name"]), conv, f["name"]))
                if f["required"]:
                    w('        else { throw realm.throwTypeError("%s: required member %s is missing") }' % (name, f["name"]))
            w("        _ = b")
            w("        return d")
            w("    }")
            w("")
        w("}")
        w("")

    def emit_interface(self, n):
        w = self.w
        i = self.ifaces[n]
        k = self.kind(n)
        glob = "Global" in i["ext"]
        w("extension JSDOMBindings {")
        w("    func gen_%s() {" % n)
        w("        unowned(unsafe) let b = self")
        w("        let realm = self.realm")
        if glob:
            w("        let p = realm.global")
        else:
            w("        let p = protos[JSDOMInterface.%s.rawValue]" % n)
        w("        _ = b; _ = realm; _ = p")
        # Interface object.
        ctor = [m for m in i["members"] if m["kind"] == "constructor"]
        if "LegacyNoInterfaceObject" not in i["ext"]:
            if ctor:
                c = ctor[0]
                length = sum(1 for a in c["args"] if not a["optional"] and not a["variadic"])
                w("        let ctor = defineInterfaceObject(.%s, length: %d) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in" % (n, length))
                w('            if !args.isConstruct { throw realm.throwTypeError("Failed to construct \'%s\': Please use the \'new\' operator") }' % n)
                w("            let rd = b.heap.rootDepth")
                w("            defer { b.heap.popRoots(to: rd) }")
                exprs = self.gen_args(n, "constructor", c["args"], "            ")
                call = "b.%s_constructor(%s)" % (n, ", ".join(exprs + ["newTarget: args.newTarget"]))
                self.sig(n + "_constructor", None, [self.arg_sig(a) for a in c["args"]] + [("JSValue", False)], "JSValue", "Throws" in c["ext"])
                # Constructors may always throw (newTarget's prototype is read).
                w("            return try %s" % call)
                w("        }")
            else:
                w("        let ctor = defineInterfaceObject(.%s, length: 0, nil)" % n)
            if "LegacyFactoryFunction" in i["ext"]:
                fname = i["ext"]["LegacyFactoryFunction"].split("(")[0]
                w('        defineFactoryFunction("%s", .%s) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in' % (fname, n))
                w("            try b.%s_factory(args)" % n)
                w("        }")
        else:
            w("        let ctor = JSValue.undefined")
        w("        _ = ctor")
        for m in i["members"]:
            kind = m["kind"]
            if kind == "const":
                w('        defineConstant(p, ctor, "%s", %s)' % (m["name"], m["value"]))
            elif kind == "attribute":
                self.emit_attribute(n, m, glob)
            elif kind == "operation":
                self.emit_operation(n, m)
            elif kind == "iterable":
                w("        defineValueIterator(p)")
            elif kind == "stringifier":
                w("        defineStringifier(p, .%s)" % n)
        has_iter = any(m["kind"] == "iterable" for m in i["members"])
        indexed = any(m["kind"] == "operation" and m.get("special") == "getter" and m["args"]
                      and self.category(m["args"][0]["type"]) == "int" for m in i["members"])
        if indexed and not has_iter:
            w("        defineIndexedIterator(p)")
        w("    }")
        w("}")
        w("")

    def emit_attribute(self, n, m, glob):
        w = self.w
        name = m["name"]
        ext = m["ext"]
        if "CEReactions" in ext:
            self.ce_members.append(n + "." + name)
        target = "ctor" if m["static"] else "p"
        c = self.category(m["type"])
        un = self.unwrap(n) if not m["static"] else None
        ill = 'b.illegal("%s", "%s")' % (n, name)
        # getter body
        body = []
        if c == "handler":
            evname = name[2:] if name.startswith("on") else name
            fwd = "true" if m.get("includeExt", {}).get("ForwardToWindow") else "false"
            body.append('return b.getEventHandler(%s, "%s", forwardToWindow: %s)' % (self.target_expr(n), evname, fwd))
        elif "Reflect" in ext:
            cname = ext["Reflect"] if ext["Reflect"] is not True else name.lower()
            if c == "bool":
                body.append('return .bool(this.hasAttribute("%s"))' % cname)
            elif c == "string":
                if "URL" in ext:
                    body.append('return b.str(b.reflectURL(this, "%s"))' % cname)
                elif m["type"].get("nullable"):
                    body.append('return b.strOrNull(this.getAttribute("%s"))' % cname)
                else:
                    body.append('return b.str(this.getAttribute("%s") ?? "")' % cname)
            elif c == "int":
                dflt = ext.get("Default", "0")
                uns = "true" if "unsigned" in self.resolve(m["type"])["name"] else "false"
                body.append('return .number(b.reflectInt(this, "%s", default: %s, unsigned: %s))' % (cname, dflt, uns))
            else:
                raise IDLError("Reflect of %s.%s" % (n, name))
        else:
            impl = self.impl_name(n, m)
            self.sig(impl, None if m["static"] else (m.get("mixin") and n or n), [], self.ret_type(m["type"]), "Throws" in ext)
            args = "" if m["static"] else "this"
            call = "b.%s(%s)" % (impl, args)
            if "Throws" in ext:
                call = "try " + call
            if "SameObject" in ext:
                # Members sharing an implementation share the cache (document.plugins === embeds).
                slot = self.same_slot(impl, "")
                body.append("return try b.sameObject(args.this, slot: %d) { () throws(JSThrow) -> JSValue in" % slot)
                body.append("    " + self.ret(m["type"], call).replace("\n            ", "\n                "))
                body.append("}")
            else:
                body.append(self.ret(m["type"], call))
        w('        defineAttribute(%s, "%s", setter: %s) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in' % (
            target, name, self.setter_closure(n, m, c, un, ill)))
        if un:
            w("            " + self.this_guard(un, ill, body))
        for l in body:
            w("            " + l)
        w("        }")
        if m["stringifier"]:
            w('        defineStringifierFrom(p, "%s")' % name)

    def setter_closure(self, n, m, c, un, ill):
        ext = m["ext"]
        name = m["name"]
        if m["readonly"]:
            if "PutForwards" in ext:
                fwd = ext["PutForwards"]
                return ('{ (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in\n'
                        '            let o = try realm.getV(args.this, b.heap.key("%s"))\n'
                        '            if !o.isObject { throw realm.throwTypeError("%s.%s is not an object") }\n'
                        '            try realm.setV(o, b.heap.key("%s"), args[0], strict: true)\n'
                        '            return .undefined\n'
                        '        }') % (name, n, name, fwd)
            if "Replaceable" in ext:
                return ('{ (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in\n'
                        '            try b.replaceAttribute(args.this, "%s", args[0])\n'
                        '            return .undefined\n'
                        '        }') % name
            return "nil"
        lines = ["{ (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in"]
        if un:
            lines.append("THIS_GUARD")
        lines.append("            let rd = b.heap.rootDepth")
        lines.append("            defer { b.heap.popRoots(to: rd) }")
        ctx = 'b.ctx("%s", "%s")' % (n, name)
        if c == "handler":
            evname = name[2:] if name.startswith("on") else name
            fwd = "true" if m.get("includeExt", {}).get("ForwardToWindow") else "false"
            lines.append('            try b.setEventHandler(%s, "%s", args[0], forwardToWindow: %s)' % (self.target_expr(n), evname, fwd))
        elif "Reflect" in ext:
            cname = ext["Reflect"] if ext["Reflect"] is not True else name.lower()
            conv = self.convert(m["type"], "args[0]", ctx, ext)
            if c == "bool":
                lines.append('            try b.reflectSetBool(this, "%s", %s)' % (cname, conv))
            elif c == "string":
                if m["type"].get("nullable"):
                    lines.append('            try b.reflectSetStringOrNull(this, "%s", %s)' % (cname, conv))
                else:
                    lines.append('            try b.reflectSetString(this, "%s", %s)' % (cname, conv))
            elif c == "int":
                lines.append('            try b.reflectSetInt(this, "%s", %s)' % (cname, conv))
        else:
            conv = self.convert(m["type"], "args[0]", ctx, ext)
            impl = self.impl_name(n, m, "set_")
            self.sig(impl, None if m["static"] else n, [(self.swift_type(m["type"]), False)], "Void", "Throws" in ext)
            lines.append("            let v = " + conv)
            call = "b.%s(%sv)" % (impl, "" if m["static"] else "this, ")
            if "Throws" in ext:
                call = "try " + call
            lines.append("            " + call)
        lines.append("            return .undefined")
        lines.append("        }")
        if un:
            g = "            " + self.this_guard(un, ill, lines[2:])
            lines = [g if l == "THIS_GUARD" else l for l in lines]
        return "\n".join(lines)

    def this_guard(self, un, ill, body):
        """`guard let this` when the body uses `this`, else a nil test."""
        for l in body:
            if re.search(r"(?<!args\.)\bthis\b", l):
                return "guard let this = %s else { throw %s }" % (un, ill)
        return "guard %s != nil else { throw %s }" % (un, ill)

    def emit_operation(self, n, m):
        w = self.w
        name = m["name"]
        if "CEReactions" in m["ext"]:
            self.ce_members.append(n + "." + name)
        target = "ctor" if m["static"] else "p"
        length = sum(1 for a in m["args"] if not a["optional"] and not a["variadic"])
        w('        defineOperation(%s, "%s", length: %d) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in' % (
            target, name, length))
        if not m["static"]:
            w('            guard let this = %s else { throw b.illegal("%s", "%s") }' % (self.unwrap(n), n, name))
        w("            let rd = b.heap.rootDepth")
        w("            defer { b.heap.popRoots(to: rd) }")
        exprs = self.gen_args(n, name, m["args"], "            ")
        impl = self.impl_name(n, m, "static_" if m["static"] else "")
        self.sig(impl, None if m["static"] else n, [self.arg_sig(a) for a in m["args"]], self.ret_type(m["ret"]), "Throws" in m["ext"])
        allargs = ([] if m["static"] else ["this"]) + exprs
        call = "b.%s(%s)" % (impl, ", ".join(allargs))
        if "Throws" in m["ext"]:
            call = "try " + call
        w("            " + self.ret(m["ret"], call))
        w("        }")
        if m["stringifier"]:
            w('        defineStringifierFrom(p, "%s", method: true)' % name)

    def emit_namespace(self, n, ns):
        w = self.w
        w("extension JSDOMBindings {")
        w("    func gen_ns_%s() {" % n)
        w("        unowned(unsafe) let b = self")
        w("        let realm = self.realm")
        w('        let p = defineNamespaceObject("%s")' % n)
        w("        _ = b")
        for m in ns["members"]:
            if m["kind"] != "operation":
                continue
            length = sum(1 for a in m["args"] if not a["optional"] and not a["variadic"])
            w('        realm.defineMethod(p, "%s", length: %d) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in' % (m["name"], length))
            w("            let rd = b.heap.rootDepth")
            w("            defer { b.heap.popRoots(to: rd) }")
            exprs = self.gen_args(n, m["name"], m["args"], "            ")
            call = "b.%s_%s(%s)" % (n, m["name"], ", ".join(exprs))
            if "Throws" in m["ext"]:
                call = "try " + call
            w("            " + self.ret(m["ret"], call))
            w("        }")
        w("    }")
        w("}")
        w("")


def main():
    check = "--check" in sys.argv
    try:
        defs, files = parse_all()
        g = Gen(defs)
        text = g.emit(files)
        if "--signatures" in sys.argv:
            for k in sorted(g.signatures):
                print(g.signatures[k])
            return 0
    except IDLError as e:
        sys.stderr.write("gen_bindings: %s\n" % e)
        return 2
    if check:
        try:
            with open(OUT) as fh:
                cur = fh.read()
        except OSError:
            cur = ""
        if cur != text:
            sys.stderr.write("gen_bindings: %s is out of date; run lib/js-dom/tools/gen_bindings.py\n" % OUT)
            return 1
        return 0
    with open(OUT, "w") as fh:
        fh.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
