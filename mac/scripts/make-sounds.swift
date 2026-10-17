// Synthesises Chirp's built-in start/stop cues, deterministically, with no third-party code.
//
//   swift scripts/make-sounds.swift                      # rewrites Assets/Sounds/*.wav
//   swift scripts/make-sounds.swift --out DIR            # writes somewhere else (scripts/check-sounds.sh does this)
//   swift scripts/make-sounds.swift --sheet FILE.png     # also draws waveform + spectrogram of every cue
//   swift scripts/make-sounds.swift --report             # prints duration / peak / loudness / edge samples
//   swift scripts/make-sounds.swift --system             # measures the stock Tink/Pop for the System pack's trim
//
// Output: 44.1 kHz, mono, 16-bit PCM WAV. Same script → same bytes (a fixed xorshift seed for the noise, no clock).
//
// PARAMETERS (also in docs/sounds.md)
//
//   chirp  (default; a soft songbird)
//     start  120 ms  sweep 2200 → 3400 Hz (exponential, front-loaded: u^0.75), vibrato 32 Hz ±2.5 % (fades in and out)
//     stop   135 ms  sweep 3000 → 2000 Hz (exponential, linear in u),            vibrato 26 Hz ±1.5 %
//            timbre: fundamental + 0.12 × 2nd + 0.04 × 3rd harmonic. Envelope: 14 / 18 ms raised-cosine attack,
//            exp(-t/τ) decay (τ 60 / 70 ms), 30 ms raised-cosine release to zero.
//   soft   (marimba / kalimba-like)
//     start  200 ms  G5 (784 Hz) then D6 (1175 Hz) 65 ms later: up a fifth
//     stop   230 ms  D6 (1175 Hz) then G5 (784 Hz) 70 ms later: down a fifth
//            each note: partials ×1 / ×4 / ×9.9 with gains 1 / 0.28 / 0.07 and decays 75 / 30 / 12 ms (exponential);
//            2 ms attack, 25 ms release.
//   glass  (bright, airy tap with a shimmer tail)
//     start  210 ms  tap at A6 (1760 Hz)       stop  250 ms  tap at E6 (1318.5 Hz)
//            partials ×1 / 2.32 / 4.25 / 6.63 (glass-bowl ratios), gains 1 / 0.45 / 0.22 / 0.10, decays 60 / 40 / 28 / 18 ms,
//            each doubled by a copy detuned +0.35 % (slow beating = the shimmer) with an 11 Hz tremolo on the tail,
//            plus a 1.5 ms high-passed noise tap. 0.6 ms attack, 30 ms release.
//   click  (minimal ticks)
//     start  60 ms   tick, damped 2400 Hz sine (τ 8 ms)  + 800 Hz body (τ 14 ms) + 0.8 ms noise
//     stop   60 ms   tick, damped 1400 Hz sine (τ 10 ms) + 600 Hz body (τ 16 ms) + 0.8 ms noise
//            0.3 ms attack, 8 ms release.
//   system  not generated: the stock Tink (start) and Pop (stop), trimmed in the app by `SoundPack.levelTrim`.
//
// LEVELS. Every cue is scaled to the same loudness (the loudest 30 ms of the A-weighted signal; the click pack 3 dB
// lower, since a tick is more salient than its energy says), then the whole set
// is lowered together until the peakiest cue peaks at -12.5 dBFS, so every peak is ≤ -12 dBFS. Every cue starts and
// ends on exact zero samples (raised-cosine fades), so there are no clicks at either end.

import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sampleRate = 44_100.0
/// The peakiest cue ends up here; the rest are quieter peaks at the same loudness.
let peakCeilingDB = -12.5

// MARK: building blocks

struct Noise {
    var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        return Double(state) / 2_147_483_648.0 - 1
    }
}

func count(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

/// Raised-cosine fade in over `attack` and out over `release`; the first and last samples are exactly zero.
func shape(_ x: [Double], attack: Double, release: Double) -> [Double] {
    var out = x
    let n = out.count
    let a = max(2, count(attack)), r = max(2, count(release))
    for i in 0..<n {
        if i < a { out[i] *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(a)) }
        let k = i - (n - r)
        if k >= 0 { out[i] *= 0.5 + 0.5 * cos(Double.pi * Double(k) / Double(r - 1)) }
    }
    out[0] = 0
    out[n - 1] = 0
    return out
}

// MARK: chirp

func chirp(duration d: Double, f0: Double, f1: Double, curve: (Double) -> Double, vibratoHz: Double, vibratoDepth: Double,
           attack: Double, tau: Double, release: Double) -> [Double] {
    let n = count(d)
    var phase = 0.0
    var out = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / sampleRate, u = t / d
        let base = f0 * pow(f1 / f0, curve(u))
        let vibrato = 1 + vibratoDepth * sin(2 * Double.pi * vibratoHz * t) * sin(Double.pi * u)
        phase += 2 * Double.pi * base * vibrato / sampleRate
        out[i] = (sin(phase) + 0.12 * sin(2 * phase) + 0.04 * sin(3 * phase)) * exp(-t / tau)
    }
    return shape(out, attack: attack, release: release)
}

// MARK: soft (marimba / kalimba)

func addMarimbaNote(_ buf: inout [Double], at start: Double, hz: Double, gain: Double) {
    let ratios = [1.0, 4.0, 9.9], amps = [1.0, 0.28, 0.07], taus = [0.075, 0.030, 0.012]
    let first = count(start)
    for i in first..<buf.count {
        let t = Double(i - first) / sampleRate
        var s = 0.0
        for k in 0..<3 { s += amps[k] * sin(2 * Double.pi * hz * ratios[k] * t) * exp(-t / taus[k]) }
        // a 2 ms attack per note, so a later note does not start with a step
        buf[i] += gain * s * min(1, t / 0.002)
    }
}

func soft(duration d: Double, notes: [(at: Double, hz: Double, gain: Double)]) -> [Double] {
    var buf = [Double](repeating: 0, count: count(d))
    for n in notes { addMarimbaNote(&buf, at: n.at, hz: n.hz, gain: n.gain) }
    return shape(buf, attack: 0.002, release: 0.025)
}

// MARK: glass

func glass(duration d: Double, hz: Double, tailTau: Double, noiseSeed: UInt32) -> [Double] {
    let ratios = [1.0, 2.32, 4.25, 6.63], amps = [1.0, 0.45, 0.22, 0.10], taus = [0.060, 0.040, 0.028, 0.018]
    var noise = Noise(seed: noiseSeed)
    var previous = 0.0
    var buf = [Double](repeating: 0, count: count(d))
    for i in 0..<buf.count {
        let t = Double(i) / sampleRate
        var s = 0.0
        for k in 0..<4 {
            let f = hz * ratios[k]
            // the tail (the long-decay part) shimmers: detuned twin partials beat, and an 11 Hz tremolo moves them
            let shimmer = 1 + 0.25 * sin(2 * Double.pi * 11 * t + Double(k)) * min(1, t / 0.02)
            let decay = exp(-t / (taus[k] * (tailTau / 0.060)))
            s += amps[k] * decay * shimmer * (sin(2 * Double.pi * f * t) + 0.6 * sin(2 * Double.pi * f * 1.0035 * t))
        }
        let n = noise.next()
        let tap = (n - previous) * exp(-t / 0.0015) * 0.35   // differentiated noise: a bright, airy tap
        previous = n
        buf[i] = s + tap
    }
    return shape(buf, attack: 0.0006, release: 0.030)
}

// MARK: click

func tick(duration d: Double, hz: Double, tau: Double, bodyHz: Double, bodyTau: Double, noiseSeed: UInt32) -> [Double] {
    var noise = Noise(seed: noiseSeed)
    var previous = 0.0
    var buf = [Double](repeating: 0, count: count(d))
    for i in 0..<buf.count {
        let t = Double(i) / sampleRate
        let n = noise.next()
        let air = (n - previous) * exp(-t / 0.0008) * 0.25
        previous = n
        buf[i] = sin(2 * Double.pi * hz * t) * exp(-t / tau) + 0.5 * sin(2 * Double.pi * bodyHz * t) * exp(-t / bodyTau) + air
    }
    return shape(buf, attack: 0.0003, release: 0.008)
}

// MARK: the set

struct Cue {
    let name: String
    let samples: [Double]
}

func rawCues() -> [Cue] {
    let fifthUp: [(at: Double, hz: Double, gain: Double)] = [(0, 783.99, 0.8), (0.065, 1174.66, 1.0)]
    let fifthDown: [(at: Double, hz: Double, gain: Double)] = [(0, 1174.66, 1.0), (0.070, 783.99, 0.75)]
    return [
        Cue(name: "chirp-start", samples: chirp(duration: 0.120, f0: 2200, f1: 3400, curve: { pow($0, 0.75) },
                                                vibratoHz: 32, vibratoDepth: 0.025, attack: 0.014, tau: 0.060, release: 0.030)),
        Cue(name: "chirp-stop", samples: chirp(duration: 0.135, f0: 3000, f1: 2000, curve: { $0 },
                                               vibratoHz: 26, vibratoDepth: 0.015, attack: 0.018, tau: 0.070, release: 0.030)),
        Cue(name: "soft-start", samples: soft(duration: 0.200, notes: fifthUp)),
        Cue(name: "soft-stop", samples: soft(duration: 0.230, notes: fifthDown)),
        Cue(name: "glass-start", samples: glass(duration: 0.210, hz: 1760, tailTau: 0.060, noiseSeed: 0xC0FFEE01)),
        Cue(name: "glass-stop", samples: glass(duration: 0.250, hz: 1318.5, tailTau: 0.075, noiseSeed: 0xC0FFEE02)),
        Cue(name: "click-start", samples: tick(duration: 0.060, hz: 2400, tau: 0.008, bodyHz: 800, bodyTau: 0.014, noiseSeed: 0xBADC0DE1)),
        Cue(name: "click-stop", samples: tick(duration: 0.060, hz: 1400, tau: 0.010, bodyHz: 600, bodyTau: 0.016, noiseSeed: 0xBADC0DE2)),
    ]
}

// MARK: measurement

struct Biquad {
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    /// Bilinear transform of (n2 s² + n1 s + n0) / (d2 s² + d1 s + d0), prewarped at `warp` Hz.
    init(n: (Double, Double, Double), d: (Double, Double, Double), warp: Double = 1000) {
        let w = 2 * Double.pi * warp
        let c = w / tan(w / (2 * sampleRate))
        func co(_ p: (Double, Double, Double)) -> (Double, Double, Double) {
            (p.0 * c * c + p.1 * c + p.2, -2 * p.0 * c * c + 2 * p.2, p.0 * c * c - p.1 * c + p.2)
        }
        let nn = co(n), dd = co(d)
        b0 = nn.0 / dd.0; b1 = nn.1 / dd.0; b2 = nn.2 / dd.0
        a1 = dd.1 / dd.0; a2 = dd.2 / dd.0
    }
    func run(_ x: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let y = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x[i]; y2 = y1; y1 = y
            out[i] = y
        }
        return out
    }
    func magnitude(at f: Double) -> Double {
        let w = 2 * Double.pi * f / sampleRate
        let (c1, s1, c2, s2) = (cos(w), -sin(w), cos(2 * w), -sin(2 * w))
        let nr = b0 + b1 * c1 + b2 * c2, ni = b1 * s1 + b2 * s2
        let dr = 1 + a1 * c1 + a2 * c2, di = a1 * s1 + a2 * s2
        return (nr * nr + ni * ni).squareRoot() / (dr * dr + di * di).squareRoot()
    }
}

/// An A-weighting filter (IEC 61672 poles, bilinear transform) normalised to 0 dB at 1 kHz.
func aWeighting() -> (filter: ([Double]) -> [Double], gain: Double) {
    let w1 = 2 * Double.pi * 20.6, w2 = 2 * Double.pi * 107.7, w3 = 2 * Double.pi * 737.9, w4 = 2 * Double.pi * 12194
    let sections = [
        Biquad(n: (1, 0, 0), d: (1, 2 * w1, w1 * w1)),
        Biquad(n: (1, 0, 0), d: (1, w2 + w3, w2 * w3)),
        Biquad(n: (0, 0, w4 * w4), d: (1, 2 * w4, w4 * w4)),
    ]
    let at1k = sections.reduce(1.0) { $0 * $1.magnitude(at: 1000) }
    return ({ x in sections.reduce(x) { $1.run($0) } }, 1 / at1k)
}

/// Loudness proxy in dB: the loudest 30 ms of the A-weighted signal (mean square). For sounds this short the ear adds
/// energy over a few tens of ms, so a tick and a chirp that read the same here sound about equally loud.
func loudnessDB(_ x: [Double]) -> Double {
    let (filter, gain) = aWeighting()
    let weighted = filter(x + [Double](repeating: 0, count: count(0.03))).map { $0 * gain }
    let window = count(0.03)
    var cumulative = [0.0]
    cumulative.reserveCapacity(weighted.count + 1)
    for v in weighted { cumulative.append(cumulative.last! + v * v) }
    var best = 0.0
    var i = 0
    while i + window <= weighted.count {
        best = max(best, (cumulative[i + window] - cumulative[i]) / Double(window))
        i += 8
    }
    return 10 * log10(max(best, 1e-30))
}

func peakDB(_ x: [Double]) -> Double { 20 * log10(max(x.map { abs($0) }.max() ?? 0, 1e-12)) }

/// Scales every cue to one loudness, then lowers the set together so the highest peak is `peakCeilingDB`.
func normalised(_ cues: [Cue]) -> [Cue] {
    let loud = cues.map { loudnessDB($0.samples) }
    let reference = loud.min()!   // match everything to the quietest-reading cue, then fit the ceiling below
    // A 60 ms tick sounds louder than its 30 ms energy suggests (transients are salient), so the click pack is
    // matched 3 dB lower. That also gives the other packs 3 dB more headroom under the −12 dBFS ceiling.
    let offset: (String) -> Double = { $0.hasPrefix("click") ? -3 : 0 }
    let matched = zip(cues, loud).map { cue, l in cue.samples.map { $0 * pow(10, (reference + offset(cue.name) - l) / 20) } }
    let worst = matched.map(peakDB).max()!
    let g = pow(10, (peakCeilingDB - worst) / 20)
    return zip(cues, matched).map { Cue(name: $0.name, samples: $1.map { $0 * g }) }
}

// MARK: WAV

func quantised(_ x: [Double]) -> [Int16] { x.map { Int16(max(-32767, min(32767, ($0 * 32767).rounded()))) } }

func wavData(_ x: [Double]) -> Data {
    let pcm = quantised(x)
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count * 2)); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count * 2))
    for s in pcm { u16(UInt16(bitPattern: s)) }
    return d
}

// MARK: spectrogram sheet

func fft(_ re: inout [Double], _ im: inout [Double]) {
    let n = re.count
    var j = 0
    for i in 1..<n {
        var bit = n >> 1
        while j & bit != 0 { j ^= bit; bit >>= 1 }
        j ^= bit
        if i < j { re.swapAt(i, j); im.swapAt(i, j) }
    }
    var len = 2
    while len <= n {
        let ang = -2 * Double.pi / Double(len)
        for start in stride(from: 0, to: n, by: len) {
            for k in 0..<len / 2 {
                let (wr, wi) = (cos(ang * Double(k)), sin(ang * Double(k)))
                let a = start + k, b = start + k + len / 2
                let tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr
                re[b] = re[a] - tr; im[b] = im[a] - ti
                re[a] += tr; im[a] += ti
            }
        }
        len <<= 1
    }
}

func color(_ v: Double) -> (CGFloat, CGFloat, CGFloat) {
    let stops: [(Double, (Double, Double, Double))] = [
        (0, (0.02, 0.02, 0.10)), (0.35, (0.25, 0.10, 0.45)), (0.65, (0.85, 0.30, 0.25)), (0.85, (0.98, 0.70, 0.20)), (1, (1, 0.98, 0.80)),
    ]
    let x = min(1, max(0, v))
    for i in 1..<stops.count where x <= stops[i].0 {
        let (a, b) = (stops[i - 1], stops[i])
        let t = (x - a.0) / (b.0 - a.0)
        return (CGFloat(a.1.0 + (b.1.0 - a.1.0) * t), CGFloat(a.1.1 + (b.1.1 - a.1.1) * t), CGFloat(a.1.2 + (b.1.2 - a.1.2) * t))
    }
    return (1, 1, 1)
}

func drawSheet(_ cues: [Cue], to url: URL) {
    let rowH = 130, labelW = 150, panelW = 760, gap = 14, axisH = 26
    let width = labelW + panelW + gap + panelW + 20, height = rowH * cues.count + axisH + 40
    let span = 0.26   // seconds on the shared time axis
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    func text(_ s: String, x: Int, y: Int, size: CGFloat = 12, bold: Bool = false) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1)]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    text("waveform (±0.30 full scale; dashed = −12 dBFS)", x: labelW, y: height - 22, bold: true)
    text("spectrogram (0–12 kHz, 60 dB range)", x: labelW + panelW + gap, y: height - 22, bold: true)

    let window = 512, hop = 32
    let hann = (0..<window).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(window - 1)) }
    // One global dB reference so cues are comparable.
    var spectra: [[[Double]]] = []
    var globalMax = 1e-12
    for cue in cues {
        var frames: [[Double]] = []
        var start = -window / 2
        while Double(start) / sampleRate < span {
            var re = (0..<window).map { i -> Double in let k = start + i; return k >= 0 && k < cue.samples.count ? cue.samples[k] * hann[i] : 0 }
            var im = [Double](repeating: 0, count: window)
            fft(&re, &im)
            let mags = (0..<window / 2).map { (re[$0] * re[$0] + im[$0] * im[$0]).squareRoot() }
            globalMax = max(globalMax, mags.max() ?? 0)
            frames.append(mags)
            start += hop
        }
        spectra.append(frames)
    }

    for (row, cue) in cues.enumerated() {
        let top = height - 40 - row * rowH
        let y0 = top - rowH + 10   // bottom of the panels
        let ph = rowH - 20
        text(cue.name, x: 12, y: y0 + ph / 2, size: 13, bold: true)
        text("\(Int((Double(cue.samples.count) / sampleRate * 1000).rounded())) ms · peak \(String(format: "%.1f", peakDB(cue.samples))) dBFS",
             x: 12, y: y0 + ph / 2 - 16, size: 10)

        // waveform
        let wx = labelW
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: wx, y: y0, width: panelW, height: ph))
        ctx.setStrokeColor(CGColor(red: 0.8, green: 0.8, blue: 0.85, alpha: 1))
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        for sign in [-1.0, 1.0] {
            let y = CGFloat(y0) + CGFloat(ph) / 2 + CGFloat(sign * 0.251 / 0.30) * CGFloat(ph) / 2
            ctx.move(to: CGPoint(x: wx, y: Int(y))); ctx.addLine(to: CGPoint(x: wx + panelW, y: Int(y)))
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setStrokeColor(CGColor(red: 0.15, green: 0.30, blue: 0.75, alpha: 1))
        ctx.setLineWidth(1)
        for px in 0..<panelW {
            let a = Int(Double(px) / Double(panelW) * span * sampleRate), b = Int(Double(px + 1) / Double(panelW) * span * sampleRate)
            guard a < cue.samples.count else { break }
            let slice = cue.samples[a..<min(max(b, a + 1), cue.samples.count)]
            let lo = slice.min() ?? 0, hi = slice.max() ?? 0
            let mid = CGFloat(y0) + CGFloat(ph) / 2, scale = CGFloat(ph) / 2 / 0.30
            ctx.move(to: CGPoint(x: wx + px, y: Int(mid + CGFloat(lo) * scale)))
            ctx.addLine(to: CGPoint(x: wx + px, y: Int(mid + CGFloat(hi) * scale) + 1))
        }
        ctx.strokePath()

        // spectrogram
        let sx = labelW + panelW + gap
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0.08, alpha: 1))
        ctx.fill(CGRect(x: sx, y: y0, width: panelW, height: ph))
        let frames = spectra[row]
        let maxBin = Int(12_000 / (sampleRate / Double(window)))
        for (fi, mags) in frames.enumerated() {
            let t = (Double(fi * hop) - Double(window / 2)) / sampleRate
            guard t >= 0 else { continue }
            let x = sx + Int(t / span * Double(panelW))
            let w = max(1, Int(Double(hop) / sampleRate / span * Double(panelW)) + 1)
            for bin in 0..<maxBin {
                let db = 20 * log10(max(mags[bin] / globalMax, 1e-9))
                let (r, g, b) = color((db + 60) / 60)
                ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
                ctx.fill(CGRect(x: x, y: y0 + bin * ph / maxBin, width: w, height: max(1, ph / maxBin + 1)))
            }
        }
    }
    // frequency ticks on the first spectrogram, which share the 0–12 kHz scale
    for khz in [0, 4, 8, 12] {
        let y = height - 40 - rowH + 10 + Int(Double(khz) / 12 * Double(rowH - 20))
        text("\(khz)k", x: labelW + panelW + gap - 20, y: min(y, height - 40 - 8) - (khz == 12 ? 8 : 0), size: 9)
    }
    // time axis
    for ms in stride(from: 0, through: 250, by: 50) {
        let off = Int(Double(ms) / 1000 / span * Double(panelW))
        text("\(ms) ms", x: labelW + off, y: 8, size: 10)
        text("\(ms) ms", x: labelW + panelW + gap + off, y: 8, size: 10)
    }
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: system sounds

func readAudio(_ url: URL) -> [Double]? {
    guard let file = try? AVAudioFile(forReading: url),
          let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate, channels: 1, interleaved: false),
          let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
    _ = fmt
    do { try file.read(into: buf) } catch { return nil }
    guard let ch = buf.floatChannelData else { return nil }
    return (0..<Int(buf.frameLength)).map { Double(ch[0][$0]) }
}

// MARK: main

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let defaultOut = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Assets/Sounds").standardized
let outDir = option("--out").map { URL(fileURLWithPath: $0) } ?? defaultOut

let cues = normalised(rawCues())

if args.contains("--system") {
    // Measures the stock sounds on the same scale. `trim` is the gain that puts them at the packs' loudness.
    let target = cues.map { loudnessDB($0.samples) }.reduce(0, +) / Double(cues.count)
    for name in ["Tink", "Pop"] {
        guard let x = readAudio(URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")) else { print("\(name): unreadable"); continue }
        let l = loudnessDB(x)
        let trim = pow(10, (target - l) / 20)
        print(String(format: "%@: %.0f ms, peak %.1f dBFS, loudness %.1f dB (packs %.1f dB) → trim %.3f (peak after trim %.1f dBFS)",
                     name, Double(x.count) / sampleRate * 1000, peakDB(x), l, target, trim, peakDB(x) + 20 * log10(trim)))
    }
    exit(0)
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for cue in cues { try wavData(cue.samples).write(to: outDir.appendingPathComponent("\(cue.name).wav")) }

if args.contains("--report") {
    print("name            dur_ms  peak_dBFS  loudness_dB  first  last  bytes")
    for cue in cues {
        let q = quantised(cue.samples)
        print(String(format: "%-15@ %6.1f  %9.2f  %11.2f  %5d  %4d  %5d", cue.name as NSString, Double(cue.samples.count) / sampleRate * 1000,
                     peakDB(cue.samples), loudnessDB(cue.samples), q.first!, q.last!, 44 + q.count * 2))
    }
}
if let sheet = option("--sheet") { drawSheet(cues, to: URL(fileURLWithPath: sheet)) }
print("wrote \(cues.count) cues to \(outDir.path)")
