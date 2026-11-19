// Trigonometry without libc (freestanding Embedded Swift has no libm):
// sin, cos, atan2 and acos by range reduction and short series, accurate to
// about 1e-11, which is plenty for geometry. Non-finite input gives 0.

let rasterPi = 3.141592653589793

func rasterSin(_ x: Double) -> Double {
    if !x.isFinite || abs(x) > 1e9 { return 0 }
    // Reduce to [-pi, pi], then to [-pi/2, pi/2].
    var r = x - 2 * rasterPi * (x / (2 * rasterPi)).rounded()
    if r > rasterPi / 2 { r = rasterPi - r } else if r < -rasterPi / 2 { r = -rasterPi - r }
    let r2 = r * r
    // Taylor to x^17.
    var term = r
    var sum = r
    var k = 1.0
    for _ in 0..<8 {
        term *= -r2 / ((k + 1) * (k + 2))
        sum += term
        k += 2
    }
    return sum
}

func rasterCos(_ x: Double) -> Double { rasterSin(x + rasterPi / 2) }

private func rasterAtanSmall(_ x: Double) -> Double {
    // |x| <= tan(pi/12): series to x^19.
    let x2 = x * x
    var term = x
    var sum = x
    var k = 1.0
    for _ in 0..<9 {
        term *= -x2
        k += 2
        sum += term / k
    }
    return sum
}

func rasterAtan(_ x: Double) -> Double {
    if x != x { return 0 }
    if x < 0 { return -rasterAtan(-x) }
    if x > 1 { return rasterPi / 2 - rasterAtan(1 / x) }
    let t12 = 0.2679491924311227   // tan(pi/12)
    if x > t12 {
        let s3 = 1.7320508075688772
        return rasterPi / 6 + rasterAtanSmall((x * s3 - 1) / (x + s3))
    }
    return rasterAtanSmall(x)
}

func rasterAtan2(_ y: Double, _ x: Double) -> Double {
    if !x.isFinite || !y.isFinite { return 0 }
    if x == 0 {
        if y > 0 { return rasterPi / 2 }
        if y < 0 { return -rasterPi / 2 }
        return 0
    }
    let a = rasterAtan(y / x)
    if x > 0 { return a }
    return y >= 0 ? a + rasterPi : a - rasterPi
}

func rasterAcos(_ x: Double) -> Double {
    let c = max(-1, min(1, x.isFinite ? x : 1))
    return rasterAtan2((1 - c * c).squareRoot(), c)
}

@inline(__always) func rasterSinF(_ x: Float) -> Float { Float(rasterSin(Double(x))) }
@inline(__always) func rasterCosF(_ x: Float) -> Float { Float(rasterCos(Double(x))) }
@inline(__always) func rasterAtan2F(_ y: Float, _ x: Float) -> Float { Float(rasterAtan2(Double(y), Double(x))) }
