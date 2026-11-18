// /bin/sysmon: system counters in a window, refreshed every second: uptime,
// compositor frames, memory frames, kernel heap, tasks, processes, windows
// and a load bar per CPU (busy timer ticks between two samples).

let app = App(title: "System monitor", width: 320, height: 240)!
let font = app.theme.font

var info = systemInfo()
var previous = info
var load = [Int](repeating: 0, count: 8)

func busy(_ i: SysInfo, _ n: Int) -> UInt64 {
    switch n {
    case 0: return i.busy0
    case 1: return i.busy1
    case 2: return i.busy2
    case 3: return i.busy3
    case 4: return i.busy4
    case 5: return i.busy5
    case 6: return i.busy6
    default: return i.busy7
    }
}

func refresh() {
    previous = info
    info = systemInfo()
    let elapsed = info.ticks &- previous.ticks
    for n in 0..<8 {
        let d = busy(info, n) &- busy(previous, n)
        load[n] = elapsed == 0 ? 0 : Int(min(d * 100 / elapsed, 100))
    }
    app.requestPaint()
}

func clock(_ ticks: UInt64) -> String {
    let s = ticks / 100
    let m = s / 60 % 60, sec = s % 60
    return "\(s / 3600):" + (m < 10 ? "0" : "") + "\(m):" + (sec < 10 ? "0" : "") + "\(sec)"
}

app.onPaint = { s in
    let th = app.theme
    var y = 8
    func row(_ name: String, _ value: String) {
        s.drawText(name, font: font, at: Point(8, y), fg: th.text, bg: nil)
        s.drawText(value, font: font, at: Point(120, y), fg: th.accent, bg: nil)
        y += 18
    }
    row("uptime", clock(info.ticks))
    row("frames", "\(info.compositorFrames) drawn")
    row("memory", "\(info.usedFrames * 4 / 1024) of \(info.totalFrames * 4 / 1024) MiB used")
    row("heap", "\(info.heapBytes / 1024) KiB in \(info.heapBlocks) blocks")
    row("tasks", "\(info.tasks)")
    row("processes", "\(info.processes)")
    row("windows", "\(info.windows)")
    y += 4
    for n in 0..<min(Int(info.cpuCount), 8) {
        s.drawText("cpu \(n)", font: font, at: Point(8, y), fg: th.text, bg: nil)
        let bar = Rect(72, y + 2, 200, 12)
        s.fill(bar, th.scrollTrack)
        s.fill(Rect(bar.x, bar.y, bar.w * load[n] / 100, bar.h), th.accent)
        s.frame(bar, th.buttonBorder)
        s.drawText("\(load[n])%", font: font, at: Point(280, y), fg: th.text, bg: nil)
        y += 18
    }
}

refresh()
app.tickInterval = 1000
app.onTick = { _ in refresh() }
Process.exit(app.run())
