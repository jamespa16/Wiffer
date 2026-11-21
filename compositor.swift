// Phase J: the compositor.
//
// The compositor owns the screen: a screen-sized RAM back buffer, an ordered
// list of layers (bottom to top) and a list of damaged rects. Nothing draws on
// the framebuffer directly any more. Changes are recorded with damage(_:), and
// composite() repaints each damaged rect in the back buffer, layer by layer
// from the bottom (starting at the topmost opaque layer that covers the rect),
// then copies just that rect out to the front surface (the framebuffer). The
// framebuffer is never read.
//
// Layers are a class hierarchy (Embedded Swift has dynamic dispatch, but
// existentials are limited): subclass Layer and override draw(into:clip:).
// Each layer sits in a band (desktop, windows, panel, cursor); add(_:) puts a
// layer on top of its band, so windows always stay under the status bar and
// the mouse cursor stays on top of everything.
//
// damage(_:) and composite() never allocate: the damage list is a fixed
// InlineArray, so they are safe on the exception-report path.

/// Z-order bands, bottom to top.
enum LayerBand: Int {
    case desktop = 0
    case windows = 1
    case panel = 2 // status bar / taskbar
    case cursor = 3
}

/// Something the compositor paints. `frame` is in screen coordinates; change
/// it (and `visible`) through the compositor so the right areas are damaged.
class Layer {
    fileprivate(set) var frame: Rect
    fileprivate(set) var visible = true
    /// Covers every pixel of its frame, so nothing below it shows through
    /// (lets the compositor skip the layers underneath).
    var opaque: Bool
    let band: LayerBand

    init(frame: Rect, band: LayerBand, opaque: Bool) {
        self.frame = frame
        self.band = band
        self.opaque = opaque
    }

    /// Paint the part of the layer inside `clip` (screen coordinates, already
    /// inside `frame`) into `s`, whose clip rect is already set to `clip`.
    /// Must not allocate.
    func draw(into s: Surface, clip: Rect) {}
}

/// A solid colour, or a colour with a grid of dots every `spacing` pixels
/// (the desktop background, drawn procedurally).
final class PatternLayer: Layer {
    var color: UInt32
    var dotColor: UInt32
    var spacing: Int

    init(frame: Rect, color: UInt32, dotColor: UInt32? = nil, spacing: Int = 8, band: LayerBand = .desktop) {
        self.color = color
        self.dotColor = dotColor ?? color
        self.spacing = max(spacing, 1)
        super.init(frame: frame, band: band, opaque: true)
    }

    override func draw(into s: Surface, clip: Rect) {
        s.fill(clip, color)
        guard dotColor != color else { return }
        // Dots where (x - frame.x) and (y - frame.y) are multiples of spacing.
        func firstAtOrAfter(_ v: Int, _ origin: Int) -> Int {
            let off = (v - origin) % spacing
            return off == 0 ? v : off > 0 ? v + spacing - off : v - off
        }
        var y = firstAtOrAfter(clip.y, frame.y)
        while y < clip.maxY {
            var x = firstAtOrAfter(clip.x, frame.x)
            while x < clip.maxX { s.plot(x, y, dotColor); x += spacing }
            y += spacing
        }
    }
}

/// A layer showing a Surface (a window's content, the console, the status
/// bar), with the surface's (0, 0) at the frame's origin.
class SurfaceLayer: Layer {
    /// Replace it (e.g. on resize) with Compositor.setSurface.
    fileprivate(set) var surface: Surface

    init(surface: Surface, at origin: Point, band: LayerBand, opaque: Bool = true) {
        self.surface = surface
        super.init(frame: Rect(origin: origin, w: surface.width, h: surface.height), band: band, opaque: opaque)
    }

    override func draw(into s: Surface, clip: Rect) {
        s.blit(from: surface, src: clip.offsetBy(dx: -frame.x, dy: -frame.y), to: clip.origin)
    }
}

/// A masked 1-bit sprite (the mouse cursor), with its top-left at the frame's
/// origin. Transparent pixels show what's underneath.
final class SpriteLayer: Layer {
    let sprite: Sprite
    var ink: UInt32
    var paper: UInt32

    init(sprite: Sprite, at origin: Point, ink: UInt32, paper: UInt32, band: LayerBand = .cursor) {
        self.sprite = sprite
        self.ink = ink
        self.paper = paper
        super.init(frame: Rect(origin: origin, w: sprite.width, h: sprite.height), band: band, opaque: false)
    }

    override func draw(into s: Surface, clip: Rect) {
        s.drawSprite(sprite, at: frame.origin, ink: ink, paper: paper)
    }
}

/// What the last frame (composite() with something to do) copied out.
struct CompositorStats {
    /// Frames that copied anything, and their totals.
    var frames = 0
    var totalRects = 0
    var totalPixels = 0
    /// The last such frame.
    var rects = 0
    var pixels = 0
    /// Layer draw calls in the last frame.
    var draws = 0
}

final class Compositor {
    /// Screen-sized RAM back buffer: every layer is painted here.
    let back: Surface
    /// Where finished rects are copied: the framebuffer (write-only), or any
    /// surface in a selftest.
    let front: Surface
    /// Bottom to top.
    private(set) var layers: [Layer] = []
    private(set) var stats = CompositorStats()

    /// Pending damage, merged so no two overlap. Past `maxDamage` rects it
    /// collapses into their bounding box.
    static let maxDamage = 16
    private var damageList = InlineArray<17, Rect>(repeating: .empty)
    private(set) var damageCount = 0

    var width: Int { back.width }
    var height: Int { back.height }
    var bounds: Rect { back.bounds }

    /// A compositor for `front`, which must be at least as large as the back
    /// buffer. The whole screen starts damaged.
    init(front: Surface, width: Int, height: Int) {
        self.front = front
        back = Surface(width: min(width, front.width), height: min(height, front.height))
        layers.reserveCapacity(16)
        damage(back.bounds)
    }

    convenience init(front: Surface) {
        self.init(front: front, width: front.width, height: front.height)
    }

    // MARK: Damage

    /// The i-th pending damage rect.
    func damageRect(_ i: Int) -> Rect { damageList[i] }

    /// Mark `r` (screen coordinates) for repainting. Never allocates.
    func damage(_ r: Rect) {
        var r = r.intersection(bounds)
        guard !r.isEmpty else { return }
        // Absorb every pending rect that overlaps; the union may then overlap
        // others, so go round again until nothing merges.
        var merged = true
        while merged {
            merged = false
            var i = 0
            while i < damageCount {
                let d = damageList[i]
                if d.contains(r) { return }
                if d.intersects(r) {
                    r = r.union(d)
                    damageCount -= 1
                    damageList[i] = damageList[damageCount]
                    merged = true
                } else {
                    i += 1
                }
            }
        }
        damageList[damageCount] = r
        damageCount += 1
        if damageCount > Compositor.maxDamage {
            var box = Rect.empty
            for i in 0..<damageCount { box = box.union(damageList[i]) }
            damageList[0] = box
            damageCount = 1
        }
    }

    /// Damage `r` given in `layer`'s coordinates (clipped to the layer).
    func damage(_ layer: Layer, local r: Rect) {
        damage(r.offsetBy(layer.frame.origin).intersection(layer.frame))
    }

    /// Damage all of `layer`.
    func damage(_ layer: Layer) { damage(layer.frame) }

    /// Repaint every damaged rect into the back buffer and copy each to the
    /// front. Never allocates.
    func composite() {
        guard damageCount > 0 else { return }
        var pixels = 0, draws = 0
        let rects = damageCount
        for i in 0..<damageCount {
            let r = damageList[i]
            draws += paint(r)
            front.blit(from: back, src: r, to: r.origin)
            pixels += r.area
        }
        damageCount = 0
        stats.frames += 1
        stats.rects = rects
        stats.pixels = pixels
        stats.draws = draws
        stats.totalRects += rects
        stats.totalPixels += pixels
    }

    /// Paint the layers under `r` into the back buffer, bottom to top,
    /// starting at the topmost visible opaque layer that covers all of `r`.
    /// Returns the number of draw calls.
    private func paint(_ r: Rect) -> Int {
        var draws = 0
        var start = 0
        var i = layers.count - 1
        while i > 0 {
            let l = layers[i]
            if l.visible && l.opaque && l.frame.contains(r) { start = i; break }
            i -= 1
        }
        // Most frames are a small update inside the top window plus the
        // transparent cursor. Keep that path free of fragment-buffer work.
        var partialCover = false
        if start + 1 < layers.count {
            for j in (start + 1)..<layers.count {
                let l = layers[j]
                if l.visible && l.opaque && l.frame.intersects(r) { partialCover = true; break }
            }
        }
        if !partialCover {
            for j in start..<layers.count {
                let l = layers[j]
                if !l.visible { continue }
                let c = l.frame.intersection(r)
                if c.isEmpty { continue }
                back.withClip(c) { l.draw(into: back, clip: c) }
                draws += 1
            }
            return draws
        }
        // Bound fragmentation and stack use. On overflow, repaint the original
        // clip for this layer; overdraw is safe and preserves exact pixels.
        var pieces = InlineArray<64, Rect>(repeating: .empty)
        var next = InlineArray<64, Rect>(repeating: .empty)
        for j in start..<layers.count {
            let l = layers[j]
            guard l.visible else { continue }
            let original = l.frame.intersection(r)
            if original.isEmpty { continue }
            pieces[0] = original
            var count = 1
            var overflow = false
            if j + 1 < layers.count {
                for k in stride(from: layers.count - 1, through: j + 1, by: -1) {
                    let above = layers[k]
                    if !above.visible || !above.opaque { continue }
                    var n = 0
                    for p in 0..<count {
                        let rect = pieces[p]
                        let cut = rect.intersection(above.frame)
                        if cut.isEmpty {
                            if n == 64 { overflow = true; break }
                            next[n] = rect; n += 1
                        } else {
                            let fragments: InlineArray<4, Rect> = [
                                Rect(rect.x, rect.y, rect.w, cut.y - rect.y),
                                Rect(rect.x, cut.maxY, rect.w, rect.maxY - cut.maxY),
                                Rect(rect.x, cut.y, cut.x - rect.x, cut.h),
                                Rect(cut.maxX, cut.y, rect.maxX - cut.maxX, cut.h)
                            ]
                            for q in 0..<4 where !fragments[q].isEmpty {
                                if n == 64 { overflow = true; break }
                                next[n] = fragments[q]; n += 1
                            }
                            if overflow { break }
                        }
                    }
                    if overflow { break }
                    for p in 0..<n { pieces[p] = next[p] }
                    count = n
                    if count == 0 { break }
                }
            }
            if overflow { pieces[0] = original; count = 1 }
            for p in 0..<count {
                let c = pieces[p]
                back.withClip(c) { l.draw(into: back, clip: c) }
                draws += 1
            }
        }
        return draws
    }

    // MARK: Layers

    /// Put `layer` on top of its band (removing it first if present).
    func add(_ layer: Layer) {
        remove(layer)
        var i = layers.count
        while i > 0 && layers[i - 1].band.rawValue > layer.band.rawValue { i -= 1 }
        layers.insert(layer, at: i)
        if layer.visible { damage(layer.frame) }
    }

    func remove(_ layer: Layer) {
        guard let i = index(of: layer) else { return }
        layers.remove(at: i)
        if layer.visible { damage(layer.frame) }
    }

    func index(of layer: Layer) -> Int? {
        for i in 0..<layers.count where layers[i] === layer { return i }
        return nil
    }

    /// Move `layer` to the top of its band (e.g. a window being focused).
    func raise(_ layer: Layer) {
        guard let i = index(of: layer) else { return }
        var j = i
        while j + 1 < layers.count && layers[j + 1].band == layer.band { j += 1 }
        guard j != i else { return }
        layers.remove(at: i)
        layers.insert(layer, at: j)
        if layer.visible { damage(layer.frame) }
    }

    /// The topmost visible layer containing `p` (for hit testing), optionally
    /// limited to one band.
    func layer(at p: Point, band: LayerBand? = nil) -> Layer? {
        var i = layers.count - 1
        while i >= 0 {
            let l = layers[i]
            if l.visible && l.frame.contains(p) && (band == nil || l.band == band!) { return l }
            i -= 1
        }
        return nil
    }

    /// Move or resize `layer`, damaging its old and new frames.
    func setFrame(_ layer: Layer, _ frame: Rect) {
        guard frame != layer.frame else { return }
        if layer.visible && index(of: layer) != nil {
            damage(layer.frame)
            damage(frame)
        }
        layer.frame = frame
    }

    func move(_ layer: Layer, to p: Point) {
        setFrame(layer, Rect(origin: p, w: layer.frame.w, h: layer.frame.h))
    }

    func setVisible(_ layer: Layer, _ visible: Bool) {
        guard visible != layer.visible else { return }
        layer.visible = visible
        if index(of: layer) != nil { damage(layer.frame) }
    }

    /// Give a SurfaceLayer a new surface (e.g. after a resize); its frame
    /// takes the surface's size.
    func setSurface(_ layer: SurfaceLayer, _ s: Surface) {
        layer.surface = s
        setFrame(layer, Rect(origin: layer.frame.origin, w: s.width, h: s.height))
        if layer.visible && index(of: layer) != nil { damage(layer.frame) }
    }
}

/// The screen's compositor (made by consoleInit with the Display), or nil
/// without a usable framebuffer.
var compositor: Compositor? = nil

func compositorInfo() -> String {
    guard let c = compositor else { return "compositor: none" }
    let s = c.stats
    return "compositor: \(c.width)x\(c.height), \(c.layers.count) layers, last frame \(s.rects) rects \(s.pixels) px (\(s.draws) layer draws); \(s.frames) frames, \(s.totalRects) rects, \(s.totalPixels) px in all"
}
