// Phase J selftests: damage merging, layer order, and compositing three
// overlapping layers off-screen into a test front surface, so what was copied
// out can be inspected (called from runSelfTests).

/// A solid-colour layer that counts its draw calls.
final class CountingLayer: Layer {
    let color: UInt32
    var draws = 0

    init(frame: Rect, color: UInt32, opaque: Bool, band: LayerBand = .windows) {
        self.color = color
        super.init(frame: frame, band: band, opaque: opaque)
    }

    override func draw(into s: Surface, clip: Rect) {
        draws += 1
        s.fill(clip, color) // the surface's clip is clip already
    }
}

/// The pending damage rects, in order.
func pendingDamage(_ c: Compositor) -> [Rect] {
    var rects: [Rect] = []
    for i in 0..<c.damageCount { rects.append(c.damageRect(i)) }
    return rects
}

func compositorTests(_ t: inout SelfTest) {
    let sentinel: UInt32 = 0xDEAD
    let front = Surface(width: 16, height: 12, color: sentinel)
    let comp = Compositor(front: front)
    t.check("compositor: starts fully damaged", pendingDamage(comp) == [Rect(0, 0, 16, 12)])

    // Three overlapping layers: an opaque desktop, an opaque surface
    // (pattern) and a non-opaque layer on top.
    let desktop = CountingLayer(frame: comp.bounds, color: 0x10, opaque: true, band: .desktop)
    let content = Surface(width: 8, height: 6)
    pattern(content, 0x1000)
    let win = SurfaceLayer(surface: content, at: Point(3, 2), band: .windows)
    let top = CountingLayer(frame: Rect(6, 5, 6, 5), color: 0x30, opaque: false, band: .panel)
    comp.add(top)
    comp.add(desktop)
    comp.add(win)
    t.check("compositor: layers ordered by band", comp.layers.count == 3 && comp.layers[0] === desktop
            && comp.layers[1] === win && comp.layers[2] === top)
    func expected(_ x: Int, _ y: Int) -> UInt32 {
        if top.frame.contains(Point(x, y)) { return 0x30 }
        if win.frame.contains(Point(x, y)) { return 0x1000 + UInt32((y - 2) * 100 + x - 3) }
        return 0x10
    }
    comp.composite()
    t.check("compositor: full composite", surfaceIs(front, expected) && surfaceIs(comp.back, expected)
            && comp.damageCount == 0 && comp.stats.rects == 1 && comp.stats.pixels == 16 * 12)

    // Damage one rect: only it is copied out, with the right pixels.
    front.fill(sentinel)
    let r = Rect(2, 3, 6, 4) // across all three layers
    comp.damage(r)
    comp.composite()
    t.check("compositor: only the damaged rect repainted",
            surfaceIs(front) { x, y in r.contains(Point(x, y)) ? expected(x, y) : sentinel })
    t.check("compositor: stats count rects and pixels", comp.stats.rects == 1 && comp.stats.pixels == 24
            && comp.stats.draws == 3 && comp.stats.frames == 2 && comp.stats.totalPixels == 16 * 12 + 24)
    comp.composite()
    t.check("compositor: nothing damaged, nothing copied", comp.stats.frames == 2)

    // An opaque layer covering the rect hides everything below it.
    let desktopDraws = desktop.draws
    front.fill(sentinel)
    comp.damage(Rect(4, 3, 2, 2))
    comp.composite()
    t.check("compositor: skips layers under an opaque cover", desktop.draws == desktopDraws
            && comp.stats.draws == 1 && surfaceIs(front) { x, y in
                Rect(4, 3, 2, 2).contains(Point(x, y)) ? expected(x, y) : sentinel })

    // Damage merging.
    comp.damage(Rect(0, 0, 4, 4))
    comp.damage(Rect(2, 2, 4, 4))
    let merged = pendingDamage(comp) == [Rect(0, 0, 6, 6)]
    comp.damage(Rect(1, 1, 2, 2)) // inside
    comp.damage(Rect(10, 0, 2, 2)) // disjoint
    comp.damage(Rect(-5, -5, 3, 3)) // off screen
    comp.damage(Rect(14, 10, 9, 9)) // clipped to the screen
    let kept = pendingDamage(comp) == [Rect(0, 0, 6, 6), Rect(10, 0, 2, 2), Rect(14, 10, 2, 2)]
    comp.damage(Rect(5, 1, 6, 1)) // bridges the first two
    t.check("compositor: overlapping damage merges", merged)
    t.check("compositor: contained, disjoint, clipped damage", kept)
    t.check("compositor: merges transitively", pendingDamage(comp) == [Rect(14, 10, 2, 2), Rect(0, 0, 12, 6)])
    comp.composite()
    let big = Compositor(front: Surface(width: 64, height: 64))
    big.composite()
    for i in 0..<Compositor.maxDamage { big.damage(Rect(i * 3, i * 2, 1, 1)) }
    let sixteen = big.damageCount == Compositor.maxDamage
    big.damage(Rect(60, 60, 1, 1))
    t.check("compositor: past 16 rects, the bounding box", sixteen
            && pendingDamage(big) == [Rect(0, 0, 61, 61)])

    // Moving a layer damages its old and new frames only.
    comp.move(top, to: Point(0, 0))
    t.check("compositor: move damages old and new frames",
            pendingDamage(comp) == [Rect(6, 5, 6, 5), Rect(0, 0, 6, 5)])
    front.fill(sentinel)
    comp.composite()
    t.check("compositor: moved layer repainted", surfaceIs(front) { x, y in
        Rect(6, 5, 6, 5).contains(Point(x, y)) || Rect(0, 0, 6, 5).contains(Point(x, y)) ? expected(x, y) : sentinel })
    comp.setVisible(top, false)
    comp.composite()
    t.check("compositor: hidden layer not drawn", front.pixel(1, 1) == 0x10 && comp.layer(at: Point(1, 1)) === desktop)
    comp.setVisible(top, true)
    comp.composite()
    t.check("compositor: hit test finds the top layer", comp.layer(at: Point(1, 1)) === top
            && comp.layer(at: Point(4, 6)) === win && comp.layer(at: Point(4, 6), band: .desktop) === desktop
            && comp.layer(at: Point(16, 0)) == nil)

    // Raise within a band; local damage.
    let win2 = CountingLayer(frame: Rect(1, 1, 4, 4), color: 0x50, opaque: true)
    comp.add(win2)
    let above = comp.index(of: win2) == 2
    comp.raise(win)
    t.check("compositor: add on top of its band, raise", above && comp.index(of: win) == 2
            && comp.index(of: win2) == 1 && comp.layers[3] === top)
    comp.remove(win2)
    comp.composite()
    comp.damage(win, local: Rect(-2, 4, 4, 9))
    t.check("compositor: damage in layer coordinates", pendingDamage(comp) == [Rect(3, 6, 2, 2)])
    comp.composite()

    // A sprite layer: transparent pixels show what's underneath.
    let sprite = Sprite(art: testSpriteArt)
    let cur = SpriteLayer(sprite: sprite, at: Point(1, 7), ink: 0xAA, paper: 0xBB)
    comp.add(cur)
    comp.composite()
    func withCursor(_ x: Int, _ y: Int) -> UInt32 {
        let v = sprite.at(x - cur.frame.x, y - cur.frame.y)
        return v == 1 ? 0xAA : v == 2 ? 0xBB : expected(x, y)
    }
    let shown = surfaceIs(comp.back, withCursor)
    front.fill(sentinel)
    comp.move(cur, to: Point(12, 1))
    comp.composite()
    t.check("compositor: sprite layer composited", shown)
    t.check("compositor: cursor move repaints old and new rects", comp.stats.rects == 2 && comp.stats.pixels == 12
            && surfaceIs(front) { x, y in
                Rect(1, 7, 3, 2).contains(Point(x, y)) || Rect(12, 1, 3, 2).contains(Point(x, y))
                    ? withCursor(x, y) : sentinel })

    // No allocation in damage/composite (safe on the exception path).
    let before = HeapUsage()
    for i in 0..<20 {
        comp.move(cur, to: Point(i % 14, i % 10))
        comp.damage(Rect(i % 7, 0, 3, 12))
        comp.composite()
    }
    t.check("compositor: damage and composite don't allocate", HeapUsage() == before)

    // The live screen: desktop, window, status bar (and the cursor).
    if let d = display, let live = compositor {
        t.check("compositor: live layers", live === d.compositor && live.layers[0] === d.desktop
                && live.index(of: d.window)! < live.index(of: d.status)!
                && (cursorLayer == nil || live.layers[live.layers.count - 1] === cursorLayer!)
                && live.back.width == d.width && live.back.height == d.height)
        consoleFlush()
        t.check("compositor: flush leaves no damage", live.damageCount == 0)
    }
}
