// /bin/clock: the wall-clock time (UTC, from the RTC) and date in a window,
// redrawn once a second: the loop is a single `wait` with a timeout (App).

let app = App(title: "Clock", width: 256, height: 112)!
let font = app.theme.font

/// `text` at `scale` times the font's size (bit-doubled glyphs).
func drawBig(_ s: Surface, _ text: String, at p: Point, scale: Int, fg: UInt32) {
    var x = p.x
    for u in text.unicodeScalars {
        let rows = font.bitmap(font.glyph(u.value))
        for r in 0..<font.height {
            let bits = rows[r]
            for c in 0..<8 where bits & (0x80 >> UInt8(c)) != 0 {
                s.fill(Rect(x + c * scale, p.y + r * scale, scale, scale), fg)
            }
        }
        x += 8 * scale
    }
}

func two(_ v: UInt64) -> String { v < 10 ? "0\(v)" : "\(v)" }

var timeText = "--:--:--"
var dateText = ""

app.onPaint = { s in
    let w = timeText.unicodeScalars.count * 16
    drawBig(s, timeText, at: Point((s.width - w) / 2, 20), scale: 2, fg: app.theme.accent)
    let dw = font.textWidth(dateText)
    s.drawText(dateText, font: font, at: Point((s.width - dw) / 2, 72), fg: app.theme.text, bg: nil)
}

func refresh() {
    let i = systemInfo()
    timeText = two(i.hour) + ":" + two(i.minute) + ":" + two(i.second)
    dateText = "\(i.year)-" + two(i.month) + "-" + two(i.day) + " UTC"
    app.requestPaint()
}

refresh()
app.tickInterval = 1000
app.onTick = { _ in refresh() }
Process.exit(app.run())
