// ES modules (ROADMAP Phase 9E item 5). Placeholder until modules land.

final class JSModuleRecord {
    func mark(_ h: JSHeap) {}
}

extension JSRealm {
    func moduleReaction(_ m: JSValue, _ v: JSValue, rejected: Bool) throws(JSThrow) {}
    func moduleBodyFinished(_ g: JSValue, ok: Bool, _ v: JSValue) throws(JSThrow) {}
}
