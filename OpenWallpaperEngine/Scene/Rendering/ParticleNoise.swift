import simd

/// The noise functions WE's particle elements sample, as `wallpaper64.exe` implements them.
/// `ParticleNoise.h` is the same code for the GPU; change both together.
///
/// - Gustavson's simplex noise ("SimplexNoise1234", Ken Perlin's permutation at 0x1404833a0):
///   1D for `turbulentvelocityrandom` (0x14027b090, scaled 0.395), 2D for `positionoffsetrandom`
///   (0x14027b170, scaled 45.2307 rather than Gustavson's 40), 3D for the `turbulence` operator
///   (0x1400fd010: `t = 0.6 − r²`, scaled 32).
/// - FastNoise2's seeded 2D simplex and its fBm, for `remapvalue`'s and `remapinitialvalue`'s
///   noise transforms (the noise object made at 0x14000c650; simplex 0x1400fb820, fBm 0x1400fb570,
///   gain 0.5 and lacunarity 2).
enum ParticleNoise {
    static let permutation: [Int] = [
        151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225,
        140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148,
        247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32,
        57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175,
        74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122,
        60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54,
        65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169,
        200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64,
        52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212,
        207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213,
        119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9,
        129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104,
        218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241,
        81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157,
        184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93,
        222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180,
    ]

    private static func perm(_ index: Int) -> Int { permutation[index & 255] }

    /// Inputs are clamped to ±1e6, which keeps the integer lattice in range (and a non-finite
    /// input at 0) on both simulations.
    static func bounded(_ value: Float) -> Float { value.isFinite ? min(max(value, -1e6), 1e6) : 0 }

    private static func floorInt(_ value: Float) -> Int {
        let truncated = Int(value)
        return Float(truncated) <= value ? truncated : truncated - 1
    }

    // MARK: - Gustavson

    static func simplex1(_ x: Float) -> Float {
        let x = bounded(x)
        func gradient(_ hash: Int, _ x: Float) -> Float {
            let h = hash & 15
            let g = 1 + Float(h & 7)
            return (h & 8) != 0 ? -g * x : g * x
        }
        let i0 = floorInt(x)
        let x0 = x - Float(i0), x1 = x0 - 1
        var t0 = 1 - x0 * x0
        t0 *= t0
        var t1 = 1 - x1 * x1
        t1 *= t1
        return 0.395 * (t0 * t0 * gradient(perm(i0), x0) + t1 * t1 * gradient(perm(i0 + 1), x1))
    }

    static func simplex2(_ x: Float, _ y: Float) -> Float {
        let x = bounded(x), y = bounded(y)
        func gradient(_ hash: Int, _ x: Float, _ y: Float) -> Float {
            let h = hash & 7
            let u = h < 4 ? x : y, v = h < 4 ? y : x
            return ((h & 1) != 0 ? -u : u) + ((h & 2) != 0 ? -2 * v : 2 * v)
        }
        let f2: Float = 0.366025403, g2: Float = 0.211324865
        let s = (x + y) * f2
        let i = floorInt(x + s), j = floorInt(y + s)
        let t = Float(i + j) * g2
        let x0 = x - (Float(i) - t), y0 = y - (Float(j) - t)
        let (i1, j1) = x0 > y0 ? (1, 0) : (0, 1)
        let x1 = x0 - Float(i1) + g2, y1 = y0 - Float(j1) + g2
        let x2 = x0 - 1 + 2 * g2, y2 = y0 - 1 + 2 * g2
        func corner(_ t: Float, _ hash: Int, _ x: Float, _ y: Float) -> Float {
            guard t >= 0 else { return 0 }
            let t2 = t * t
            return t2 * t2 * gradient(hash, x, y)
        }
        let n0 = corner(0.5 - x0 * x0 - y0 * y0, perm(i + perm(j)), x0, y0)
        let n1 = corner(0.5 - x1 * x1 - y1 * y1, perm(i + i1 + perm(j + j1)), x1, y1)
        let n2 = corner(0.5 - x2 * x2 - y2 * y2, perm(i + 1 + perm(j + 1)), x2, y2)
        return 45.2307 * (n0 + n1 + n2)
    }

    private static let gradients3: [SIMD3<Float>] = [
        SIMD3(1, 1, 0), SIMD3(-1, 1, 0), SIMD3(1, -1, 0), SIMD3(-1, -1, 0),
        SIMD3(1, 0, 1), SIMD3(-1, 0, 1), SIMD3(1, 0, -1), SIMD3(-1, 0, -1),
        SIMD3(0, 1, 1), SIMD3(0, -1, 1), SIMD3(0, 1, -1), SIMD3(0, -1, -1),
    ]

    static func simplex3(_ x: Float, _ y: Float, _ z: Float) -> Float {
        let x = bounded(x), y = bounded(y), z = bounded(z)
        let f3: Float = 1.0 / 3.0, g3: Float = 1.0 / 6.0
        let s = (x + y + z) * f3
        let i = floorInt(x + s), j = floorInt(y + s), k = floorInt(z + s)
        let t = Float(i + j + k) * g3
        let p0 = SIMD3(x - (Float(i) - t), y - (Float(j) - t), z - (Float(k) - t))
        let o1: SIMD3<Int32>, o2: SIMD3<Int32>
        if p0.x >= p0.y {
            if p0.y >= p0.z { o1 = SIMD3(1, 0, 0); o2 = SIMD3(1, 1, 0) }
            else if p0.x >= p0.z { o1 = SIMD3(1, 0, 0); o2 = SIMD3(1, 0, 1) }
            else { o1 = SIMD3(0, 0, 1); o2 = SIMD3(1, 0, 1) }
        } else {
            if p0.y < p0.z { o1 = SIMD3(0, 0, 1); o2 = SIMD3(0, 1, 1) }
            else if p0.x < p0.z { o1 = SIMD3(0, 1, 0); o2 = SIMD3(0, 1, 1) }
            else { o1 = SIMD3(0, 1, 0); o2 = SIMD3(1, 1, 0) }
        }
        let p1 = p0 - SIMD3<Float>(o1) + g3
        let p2 = p0 - SIMD3<Float>(o2) + 2 * g3
        let p3 = p0 - 1 + 3 * g3
        func corner(_ p: SIMD3<Float>, _ offset: SIMD3<Int32>) -> Float {
            let t = 0.6 - simd_length_squared(p)
            guard t >= 0 else { return 0 }
            let index = perm(i + Int(offset.x) + perm(j + Int(offset.y) + perm(k + Int(offset.z)))) % 12
            let t2 = t * t
            return t2 * t2 * simd_dot(gradients3[index], p)
        }
        return 32 * (corner(p0, .zero) + corner(p1, o1) + corner(p2, o2) + corner(p3, SIMD3(1, 1, 1)))
    }

    // MARK: - FastNoise2

    private static let primeX: Int32 = 501_125_321, primeY: Int32 = 1_136_930_381

    /// FastNoise2's seeded simplex at (x, y), about −1…1.
    static func seededSimplex2(seed: Int32, _ x: Float, _ y: Float) -> Float {
        let x = bounded(x), y = bounded(y)
        let f2: Float = 0.366025403784438646763723170752936183, g2: Float = 0.211324865405187117745425609748
        let f = f2 * (x + y)
        let fx0 = (x + f).rounded(.down), fy0 = (y + f).rounded(.down)
        let i = Int32(fx0) &* primeX, j = Int32(fy0) &* primeY
        let g = g2 * (fx0 + fy0)
        let x0 = x - (fx0 - g), y0 = y - (fy0 - g)
        let firstX = x0 > y0
        let x1 = (firstX ? x0 - 1 : x0) + g2, y1 = (firstX ? y0 : y0 - 1) + g2
        let x2 = x0 + (2 * g2 - 1), y2 = y0 + (2 * g2 - 1)
        func falloff(_ x: Float, _ y: Float) -> Float {
            let t = max(0.5 - x * x - y * y, 0)
            let t2 = t * t
            return t2 * t2
        }
        let n0 = gradientDot(hash(seed, i, j), x0, y0)
        let n1 = gradientDot(hash(seed, firstX ? i &+ primeX : i, firstX ? j : j &+ primeY), x1, y1)
        let n2 = gradientDot(hash(seed, i &+ primeX, j &+ primeY), x2, y2)
        return 38.283687591552734375 * (n0 * falloff(x0, y0) + n1 * falloff(x1, y1) + n2 * falloff(x2, y2))
    }

    /// FastNoise2's fBm of `seededSimplex2` over `octaves`, normalised by the amplitudes' sum.
    static func seededFBm2(seed: Int32, _ x: Float, _ y: Float, octaves: Int) -> Float {
        let count = max(octaves, 1)
        var amplitude = fractalBounding(octaves: count)
        var sum = seededSimplex2(seed: seed, x, y) * amplitude
        var frequency: Float = 1
        var octaveSeed = seed
        for _ in 1..<count {
            frequency *= 2
            octaveSeed &+= 1
            amplitude *= 0.5
            sum += seededSimplex2(seed: octaveSeed, x * frequency, y * frequency) * amplitude
        }
        return sum
    }

    /// 1 / Σ 0.5ⁱ over the octaves.
    static func fractalBounding(octaves: Int) -> Float {
        var total: Float = 0, amplitude: Float = 1
        for _ in 0..<max(octaves, 1) {
            total += amplitude
            amplitude *= 0.5
        }
        return 1 / total
    }

    private static func hash(_ seed: Int32, _ x: Int32, _ y: Int32) -> Int32 {
        let h = (seed ^ x ^ y) &* 0x27d4_eb2d
        return (h >> 15) ^ h
    }

    private static func gradientDot(_ hash: Int32, _ x: Float, _ y: Float) -> Float {
        let fx = (hash & 1) != 0 ? -x : x
        let fy = (hash & 2) != 0 ? -y : y
        let swapped = (hash & 4) != 0
        let a = swapped ? fy : fx, b = swapped ? fx : fy
        return (1 + 1.41421356237309504880) * a + b
    }
}
