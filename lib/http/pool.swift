// Connection pool policy: bookkeeping only (no sockets). The browser's event
// loop asks `acquire` for a connection to an origin, opens/uses it, and
// reports back with `release`/`remove`.
//
//   switch pool.acquire(key, now: now) {
//   case .reuse(let id): send on the idle connection `id` (if it turns out
//       to be dead before any response byte, retry once on a new connection
//       when the request is idempotent)
//   case .open(let id):  create a connection, associate it with `id`
//   case .wait:          6 connections to this origin are busy; queue the request
//   }
//   pool.release(id, reusable: keepAlive, now: now)   // response complete
//   pool.remove(id)                                   // closed / failed
//   for id in pool.drainClosable() { close(id) }      // evictions / expiry

struct HTTPOriginKey: Equatable {
    var scheme: [UInt8]
    var host: [UInt8]
    var port: UInt16

    init(url: URLRecord) {
        scheme = url.scheme
        host = url.hostBytes
        port = url.effectivePort ?? 0
    }
}

enum HTTPPoolAcquire: Equatable {
    case reuse(Int)
    case open(Int)
    case wait
}

struct HTTPPoolConnection {
    var id: Int
    var key: HTTPOriginKey
    var busy: Bool
    var idleSince: Int
    var uses: Int
}

struct HTTPConnectionPool {
    var maxPerHost = 6
    var maxTotal = 32
    var idleTimeout = 60
    var maxUsesPerConnection = 100

    private(set) var connections: [HTTPPoolConnection] = []
    private var nextID = 1
    private var closable: [Int] = []

    init() {}

    var totalCount: Int { connections.count }

    func count(for key: HTTPOriginKey) -> (busy: Int, idle: Int) {
        var b = 0, i = 0
        for c in connections where c.key == key { if c.busy { b += 1 } else { i += 1 } }
        return (b, i)
    }

    mutating func acquire(_ key: HTTPOriginKey, now: Int) -> HTTPPoolAcquire {
        expireIdle(now: now)
        // most recently used idle connection first
        var best = -1
        for (i, c) in connections.enumerated() where c.key == key && !c.busy {
            if best < 0 || c.idleSince >= connections[best].idleSince { best = i }
        }
        if best >= 0 {
            connections[best].busy = true
            connections[best].uses += 1
            return .reuse(connections[best].id)
        }
        let (busy, idle) = count(for: key)
        if busy + idle >= maxPerHost { return .wait }
        if connections.count >= maxTotal {
            // make room by closing the oldest idle connection to another origin
            var victim = -1
            for (i, c) in connections.enumerated() where !c.busy {
                if victim < 0 || c.idleSince < connections[victim].idleSince { victim = i }
            }
            if victim < 0 { return .wait }
            closable.append(connections[victim].id)
            connections.remove(at: victim)
        }
        let id = nextID
        nextID += 1
        connections.append(HTTPPoolConnection(id: id, key: key, busy: true, idleSince: now, uses: 1))
        return .open(id)
    }

    /// A request on `id` finished. If `reusable` (keep-alive, body fully
    /// read) the connection goes idle; otherwise it is dropped and its id
    /// returned in drainClosable. Returns whether the connection is kept.
    @discardableResult
    mutating func release(_ id: Int, reusable: Bool, now: Int) -> Bool {
        guard let i = connections.firstIndex(where: { $0.id == id }) else { return false }
        if !reusable || connections[i].uses >= maxUsesPerConnection {
            closable.append(id)
            connections.remove(at: i)
            return false
        }
        connections[i].busy = false
        connections[i].idleSince = now
        return true
    }

    /// The connection is gone (closed by the peer, errored). No close needed.
    mutating func remove(_ id: Int) {
        if let i = connections.firstIndex(where: { $0.id == id }) { connections.remove(at: i) }
    }

    /// Drop idle connections older than idleTimeout (they go to drainClosable).
    mutating func expireIdle(now: Int) {
        var i = 0
        while i < connections.count {
            if !connections[i].busy && now - connections[i].idleSince >= idleTimeout {
                closable.append(connections[i].id)
                connections.remove(at: i)
            } else { i += 1 }
        }
    }

    /// Ids the owner should close now (evicted, expired or non-reusable).
    mutating func drainClosable() -> [Int] {
        let c = closable
        closable = []
        return c
    }
}
