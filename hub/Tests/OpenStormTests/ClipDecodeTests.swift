import AVFoundation
import XCTest
@testable import OpenStormCore

/// The hub decodes clips with AVAudioFile because AVAudioPlayer refuses to start most of the game's Ogg Vorbis
/// (play() returns false). This checks the decoder on a sample of every kind of clip in the game. Nothing is played.
final class ClipDecodeTests: XCTestCase {
    func testGameClipsDecode() throws {
        do {
            let edition = SilentStormEdition.silentStorm
            try XCTSkipUnless(FileManager.default.fileExists(atPath: edition.dataDirectory.appendingPathComponent(edition.databaseFileName).path))
            let lib = try GameLibrary.load(edition.location)
            let sounds = edition.location.sounds()
            let groups: [(String, [Int32])] = [
                ("voice", Array(Set(lib.lines.flatMap(\.soundIDs))).sorted()),
                ("hit", Array(Set(lib.characters.flatMap(\.hitSoundIDs))).sorted()),
                ("death", Array(Set(lib.characters.flatMap(\.deathSoundIDs))).sorted()),
                ("catalog", lib.sounds.map(\.id)),
            ]
            for (label, all) in groups {
                let shipped = all.filter { sounds.data(id: $0) != nil }
                let sample = stride(from: 0, to: shipped.count, by: max(1, shipped.count / 150)).map { shipped[$0] }
                var decoded = 0
                for id in sample {
                    let data = sounds.data(id: id)!
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-test-\(id).\(data.starts(with: [0x4F, 0x67, 0x67]) ? "ogg" : "wav")")
                    defer { try? FileManager.default.removeItem(at: url) }
                    try data.write(to: url)
                    if let f = try? AVAudioFile(forReading: url), f.length > 0,
                       let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
                       (try? f.read(into: b)) != nil, b.frameLength > 0 { decoded += 1 }
                }
                print("\(edition.rawValue) \(label): \(decoded) of \(sample.count) sampled clips decode")
                XCTAssertGreaterThanOrEqual(Double(decoded), Double(sample.count) * 0.98, "\(edition.rawValue) \(label)")
            }
        }
    }
}
