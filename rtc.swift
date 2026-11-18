// Part 5 (Phase V3): wall-clock time from the CMOS real-time clock (index
// port 0x70, data 0x71), for FAT timestamps. Registers 0x00-0x09 hold
// seconds, minutes, hours, weekday, day, month and year (two digits), in BCD
// unless status register B says binary; hours may be 12-hour with bit 7 =
// PM. No century register is trusted: years are 2000-2099.

typealias RTCTime = (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)

/// Used when the RTC can't be read or holds nonsense.
let rtcFallback: RTCTime = (year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0)

private func cmosRead(_ register: UInt8) -> UInt8 {
    outb(0x70, register) // bit 7 clear: NMIs stay enabled
    return inb(0x71)
}

private struct RTCRaw: Equatable {
    var second: UInt8, minute: UInt8, hour: UInt8, day: UInt8, month: UInt8, year: UInt8
}

/// Raw registers, read outside an update cycle (status A bit 7).
/// False if the update flag never cleared.
private func cmosSnapshot(_ out: inout RTCRaw) -> Bool {
    var spins = 0
    while cmosRead(0x0A) & 0x80 != 0 {
        spins += 1
        if spins > 100_000 { return false }
        cpu_pause()
    }
    out = RTCRaw(second: cmosRead(0x00), minute: cmosRead(0x02), hour: cmosRead(0x04),
                 day: cmosRead(0x07), month: cmosRead(0x08), year: cmosRead(0x09))
    return true
}

/// Current date and time (UTC as QEMU presents it), or rtcFallback.
func rtcNow() -> RTCTime {
    // Read until two snapshots agree, so a rollover between registers
    // (e.g. 23:59:59 -> 00:00:00) can't mix two times.
    var a = RTCRaw(second: 0, minute: 0, hour: 0, day: 0, month: 0, year: 0)
    var b = a
    guard cmosSnapshot(&a) else { return rtcFallback }
    var tries = 0
    while true {
        guard cmosSnapshot(&b) else { return rtcFallback }
        if a == b { break }
        a = b
        tries += 1
        if tries > 5 { return rtcFallback }
    }
    return rtcDecode(second: a.second, minute: a.minute, hour: a.hour, day: a.day, month: a.month, year: a.year,
                     statusB: cmosRead(0x0B)) ?? rtcFallback
}

/// Convert raw RTC registers (status B bit 2 = binary, bit 1 = 24-hour).
/// nil if any field is out of range.
func rtcDecode(second: UInt8, minute: UInt8, hour: UInt8, day: UInt8, month: UInt8, year: UInt8,
               statusB: UInt8) -> RTCTime? {
    let binary = statusB & 0x04 != 0
    let hour24 = statusB & 0x02 != 0
    func value(_ v: UInt8) -> Int? {
        if binary { return Int(v) }
        let hi = Int(v >> 4), lo = Int(v & 0x0F)
        guard hi < 10, lo < 10 else { return nil }
        return hi * 10 + lo
    }
    let pm = !hour24 && hour & 0x80 != 0
    guard let s = value(second), let m = value(minute), var h = value(hour & 0x7F),
          let d = value(day), let mo = value(month), let y = value(year) else { return nil }
    if !hour24 {
        guard h >= 1, h <= 12 else { return nil }
        h = h % 12 + (pm ? 12 : 0)
    }
    guard s < 60, m < 60, h < 24, d >= 1, d <= 31, mo >= 1, mo <= 12, y < 100 else { return nil }
    return (year: 2000 + y, month: mo, day: d, hour: h, minute: m, second: s)
}

func rtcTests(_ t: inout SelfTest) {
    let now = rtcNow()
    t.check("rtc: rtcNow in range", now.year >= 2000 && now.year < 2100 && (1...12).contains(now.month)
        && (1...31).contains(now.day) && now.hour < 24 && now.minute < 60 && now.second < 60)
    let bcd = rtcDecode(second: 0x59, minute: 0x30, hour: 0x23, day: 0x18, month: 0x11, year: 0x26, statusB: 0x02)
    let pm = rtcDecode(second: 0, minute: 0, hour: 0x80 | 0x12, day: 1, month: 1, year: 0x26, statusB: 0x00)
    let am = rtcDecode(second: 0, minute: 0, hour: 0x12, day: 1, month: 1, year: 0x26, statusB: 0x00)
    let bin = rtcDecode(second: 5, minute: 6, hour: 7, day: 8, month: 9, year: 26, statusB: 0x06)
    t.check("rtc: decode BCD, 12-hour, binary",
            bcd.map { $0 == (year: 2026, month: 11, day: 18, hour: 23, minute: 30, second: 59) } == true
            && pm?.hour == 12 && am?.hour == 0
            && bin.map { $0 == (year: 2026, month: 9, day: 8, hour: 7, minute: 6, second: 5) } == true
            && rtcDecode(second: 0x5A, minute: 0, hour: 0, day: 1, month: 1, year: 0, statusB: 0x02) == nil
            && rtcDecode(second: 0, minute: 0, hour: 0, day: 1, month: 0x13, year: 0, statusB: 0x02) == nil)
}
