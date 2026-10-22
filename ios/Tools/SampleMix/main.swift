import AVFoundation
import Foundation

// Makes a synthetic .passablemix for trying the iPhone app without a Mac set:
// four made-up songs (a kick, hats, a bass line and a pad each, at their own
// tempo and key) laid out with real crossfaded blends, and the map to match.
//
//   swiftc -O Tools/SampleMix/main.swift ../Passable/Model/PassableMix.swift -o /tmp/make-sample-mix
//   /tmp/make-sample-mix "Samples/Sample Set.passablemix"

let sampleRate = 44_100.0
struct Spec {
    var artist: String, title: String
    var bpm: Double, root: Double, key: String, seconds: Double, minor: Bool
}
let specs = [
    Spec(artist: "Neon Harbor", title: "Midnight Drive", bpm: 118, root: 55.0, key: "8A", seconds: 70, minor: true),
    Spec(artist: "Glass Animals Club", title: "Slow Static", bpm: 120, root: 61.74, key: "10A", seconds: 66, minor: true),
    Spec(artist: "Okta", title: "Paper Planes", bpm: 124, root: 65.41, key: "8B", seconds: 72, minor: false),
    Spec(artist: "The Low Tide", title: "Afterglow", bpm: 126, root: 73.42, key: "3B", seconds: 74, minor: false),
]
let blend = 14.0      // seconds of overlap between songs
let styles = ["Stem Swap", "Drop Swap", "Long Blend"]

func render(_ spec: Spec) -> [[Float]] {
    let n = Int(spec.seconds * sampleRate)
    var left = [Float](repeating: 0, count: n), right = left
    let beat = 60.0 / spec.bpm
    let beats = Int(spec.seconds / beat)
    var seed: UInt64 = UInt64(spec.title.hashValue & 0xFFFF) | 1
    func noise() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: seed >> 11) % 2000) / 1000 - 1
    }
    let third = spec.minor ? 1.1892 : 1.2599, fifth = 1.4983
    for b in 0..<beats {
        let t0 = Double(b) * beat
        let i0 = Int(t0 * sampleRate)
        // Kick: a falling sine.
        for k in 0..<Int(0.22 * sampleRate) where i0 + k < n {
            let t = Double(k) / sampleRate
            let f = 48 + 90 * exp(-t * 28)
            let v = Float(sin(2 * .pi * f * t) * exp(-t * 9) * 0.9)
            left[i0 + k] += v; right[i0 + k] += v
        }
        // Hat on the off-beat.
        let h0 = i0 + Int(beat / 2 * sampleRate)
        for k in 0..<Int(0.05 * sampleRate) where h0 + k < n {
            let v = noise() * Float(exp(-Double(k) / sampleRate * 90)) * 0.16
            left[h0 + k] += v * 0.9; right[h0 + k] += v * 1.1
        }
        // Bass: root, then the fifth, every other beat.
        if b % 2 == 0 {
            let f = spec.root * (b % 8 < 4 ? 1 : 1.3348) * 2
            for k in 0..<Int(beat * 1.8 * sampleRate) where i0 + k < n {
                let t = Double(k) / sampleRate
                let v = Float(sin(2 * .pi * f * t) * exp(-t * 2.4) * 0.42)
                left[i0 + k] += v; right[i0 + k] += v
            }
        }
    }
    // A slow pad on the chord, swelling in and out.
    for (m, mult) in [4.0, 4.0 * third, 4.0 * fifth].enumerated() {
        let f = spec.root * mult
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let swell = Float(0.5 - 0.5 * cos(2 * .pi * t / 16))
            let v = Float(sin(2 * .pi * f * t + Double(m))) * 0.07 * (0.35 + 0.65 * swell)
            left[i] += v * (m == 0 ? 1.0 : 0.6); right[i] += v * (m == 2 ? 1.0 : 0.6)
        }
    }
    return [left, right]
}

// Lay the songs out with their blends.
var starts: [Double] = [0]
for i in 1..<specs.count { starts.append(starts[i - 1] + specs[i - 1].seconds - blend) }
let total = starts.last! + specs.last!.seconds
let frames = Int(total * sampleRate)
var mixL = [Float](repeating: 0, count: frames), mixR = mixL

for (i, spec) in specs.enumerated() {
    let song = render(spec)
    let offset = Int(starts[i] * sampleRate)
    let fadeFrames = Int(blend * sampleRate)
    for k in 0..<song[0].count where offset + k < frames {
        var gain: Float = 1
        if i > 0 && k < fadeFrames { gain *= Float(sin(Double(k) / Double(fadeFrames) * .pi / 2)) }
        if i < specs.count - 1 && k > song[0].count - fadeFrames {
            gain *= Float(cos(Double(k - (song[0].count - fadeFrames)) / Double(fadeFrames) * .pi / 2))
        }
        mixL[offset + k] += song[0][k] * gain
        mixR[offset + k] += song[1][k] * gain
    }
}
let peak = max(mixL.map(abs).max() ?? 1, mixR.map(abs).max() ?? 1)
let norm = 0.85 / peak
for i in 0..<frames { mixL[i] *= norm; mixR[i] *= norm }

// Write the AAC file (with a few seconds of tail, as Passable does).
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sample-\(UUID().uuidString).m4a")
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
do {
    let file = try AVAudioFile(forWriting: temp, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let block = 1 << 15
    var written = 0
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
    while written < frames {
        let n = min(block, frames - written)
        buffer.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { buffer.floatChannelData![0][i] = mixL[written + i]; buffer.floatChannelData![1][i] = mixR[written + i] }
        try file.write(from: buffer)
        written += n
    }
}

// The map.
var songs: [PassableMix.Song] = []
var transitions: [PassableMix.Transition] = []
for (i, spec) in specs.enumerated() {
    let into = i > 0 ? starts[i] : 0.0
    let outOf = i < specs.count - 1 ? starts[i + 1] + blend : total
    songs.append(.init(index: i, title: spec.title, artist: spec.artist,
                       start: into, handover: i > 0 ? into + blend / 2 : 0, solo: i > 0 ? into + blend : 0,
                       end: outOf, bpm: spec.bpm, key: spec.key))
    if i > 0 {
        transitions.append(.init(from: i - 1, to: i, begins: into, handover: into + blend / 2, end: into + blend,
                                 style: styles[(i - 1) % styles.count],
                                 notes: i == 2 ? ["B's vocal sings over A's beat"] : []))
    }
}
let manifest = PassableMix.Manifest(title: "Sample Set", source: "make-sample-mix", duration: total,
                                    audio: .init(size: 0), songs: songs, transitions: transitions)
let destination = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sample Set.passablemix")
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try PassableMix.write(manifest, audio: temp, to: destination)
try? FileManager.default.removeItem(at: temp)
print("Wrote \(destination.path): \(songs.count) songs, \(Int(total)) s")
