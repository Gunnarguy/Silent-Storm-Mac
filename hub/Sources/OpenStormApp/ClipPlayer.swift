import AVFoundation
import SwiftUI
import OpenStormCore

/// Something the hub can play: a clip from the game's archives or a music file.
struct PlayableClip: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let fileURL: URL?
    let soundID: Int32

    init(soundID: Int32, title: String, subtitle: String = "") {
        self.id = "sound-\(soundID)"
        self.soundID = soundID
        self.title = title
        self.subtitle = subtitle
        self.fileURL = nil
    }

    init(file: URL) {
        self.id = file.path
        self.soundID = 0
        self.title = file.deletingPathExtension().lastPathComponent
        self.subtitle = file.deletingLastPathComponent().lastPathComponent
        self.fileURL = file
    }
}

/// Plays game audio. Clips are decoded with AVAudioFile and played through an AVAudioEngine. AVAudioPlayer opens the
/// game's Ogg Vorbis clips and reports their length, but its play() returns false for about 95% of them (measured
/// 2026-11-02 over 1,200 clips of the game), which left the button on stop with nothing moving.
@MainActor
final class ClipPlayer: NSObject, ObservableObject {
    @Published private(set) var currentID: String?
    @Published private(set) var current: PlayableClip?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var message: String?
    @Published var volume: Float = 0.8 { didSet { node.volume = volume } }

    var soundSource: ResourceSet?
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var sampleRate: Double = 44_100
    /// Bumped on every play and stop, so a completion from a clip that was cut off does nothing.
    private var generation = 0
    private var queue: [PlayableClip] = []
    private var timer: Timer?

    override init() {
        super.init()
        engine.attach(node)
    }

    func toggle(_ clip: PlayableClip) {
        if currentID == clip.id, isPlaying { stop() } else { play(clip) }
    }

    func playAll(_ clips: [PlayableClip]) {
        queue = Array(clips.dropFirst())
        if let first = clips.first { play(first, keepQueue: true) }
    }

    func play(_ clip: PlayableClip, keepQueue: Bool = false) {
        if !keepQueue { queue = [] }
        halt()
        current = clip
        currentID = clip.id
        waveform = []
        // Music is played from its file; a game clip is decoded whole, it is a few seconds long.
        let file: AVAudioFile?
        var buffer: AVAudioPCMBuffer?
        if let url = clip.fileURL {
            file = try? AVAudioFile(forReading: url)
        } else if let data = soundSource?.data(id: clip.soundID) {
            buffer = ClipPlayer.decode(data)
            file = nil
        } else {
            file = nil
        }
        guard let format = buffer?.format ?? file?.processingFormat,
              let frames = buffer.map({ AVAudioFramePosition($0.frameLength) }) ?? file?.length, frames > 0 else {
            message = "This clip could not be read"
            return
        }
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { if !engine.isRunning { try engine.start() } } catch {
            message = "Audio output could not start"
            return
        }
        message = nil
        sampleRate = format.sampleRate
        duration = Double(frames) / format.sampleRate
        progress = 0
        node.volume = volume
        let token = generation
        let done: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            Task { @MainActor in self?.clipEnded(token) }
        }
        if let buffer {
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack, completionHandler: done)
            waveform = ClipPlayer.waveform(of: buffer)
        } else if let file {
            node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack, completionHandler: done)
        }
        node.play()
        isPlaying = true
        startTimer()
        if let url = clip.fileURL {
            let id = clip.id
            Task { [weak self] in
                let bars = await Task.detached(priority: .utility) { ClipPlayer.waveform(ofFile: url) }.value
                guard let self, self.currentID == id else { return }
                self.waveform = bars
            }
        }
    }

    func stop() {
        queue = []
        halt()
    }

    /// Cuts the clip off; its completion arrives with an old generation and is ignored.
    private func halt() {
        generation += 1
        node.stop()
        isPlaying = false
        progress = 0
        timer?.invalidate()
        timer = nil
    }

    private func clipEnded(_ token: Int) {
        guard token == generation else { return }
        halt()
        if !queue.isEmpty {
            let next = queue.removeFirst()
            play(next, keepQueue: true)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.duration > 0, let render = self.node.lastRenderTime,
                      let time = self.node.playerTime(forNodeTime: render) else { return }
                self.progress = min(1, Double(time.sampleTime) / self.sampleRate / self.duration)
            }
        }
    }

    /// AVAudioFile reads from a file, so the clip goes through a temporary one.
    nonisolated static func decode(_ data: Data) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hub-clip-\(UUID().uuidString).\(data.starts(with: [0x4F, 0x67, 0x67]) ? "ogg" : "wav")")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil, let file = try? AVAudioFile(forReading: url),
              file.length > 0, file.length < 48_000 * 600,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else { return nil }
        return buffer
    }

    nonisolated static func waveform(ofFile url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0, file.length < 48_000 * 600,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return [] }
        return waveform(of: buffer)
    }

    /// Peak level of the decoded audio in 96 bars.
    nonisolated static func waveform(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let frames = Int(buffer.frameLength), bars = 96
        guard frames >= bars else { return [] }
        var out = [Float](repeating: 0, count: bars)
        for i in 0..<frames {
            let b = i * bars / frames
            out[b] = max(out[b], abs(channel[i]))
        }
        let top = max(out.max() ?? 1, 0.001)
        return out.map { $0 / top }
    }
}

struct PlayerBar: View {
    @ObservedObject var player: ClipPlayer

    var body: some View {
        if let clip = player.current {
            HStack(spacing: 12) {
                Button {
                    player.toggle(clip)
                } label: {
                    Image(systemName: player.isPlaying ? "stop.fill" : "play.fill").frame(width: 18)
                }
                .buttonStyle(.borderless)
                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text(player.message ?? clip.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 260, alignment: .leading)
                GeometryReader { geo in
                    HStack(alignment: .center, spacing: 1) {
                        ForEach(Array(player.waveform.enumerated()), id: \.offset) { i, level in
                            let played = Double(i) / Double(max(1, player.waveform.count)) <= player.progress
                            RoundedRectangle(cornerRadius: 1)
                                .fill(played && player.isPlaying ? Color.accentColor : Color.white.opacity(0.28))
                                .frame(height: max(2, CGFloat(level) * geo.size.height))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 30)
                Text(String(format: "%.1f s", player.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1).frame(width: 90)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }
}
