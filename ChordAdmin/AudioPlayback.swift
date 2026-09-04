import Foundation
import AVFoundation
import Combine

// MARK: - Audio player

@MainActor
final class ChordAudioPlayer: NSObject, ObservableObject {
    @Published var currentTime: Double = 0
    @Published var isPlaying: Bool = false
    @Published var duration: Double = 0
    @Published var isLoaded: Bool = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedPath: String?

    func load(path: String) {
        guard path != loadedPath else { return }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        loadedPath = path
        duration = player.duration
        currentTime = 0
        isLoaded = true
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            stopTimer()
            isPlaying = false
        } else {
            player.play()
            startTimer()
            isPlaying = true
        }
    }

    func pause() {
        guard let player, player.isPlaying else { return }
        player.pause()
        stopTimer()
        isPlaying = false
    }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
    }


    func stop() {
        player?.stop()
        stopTimer()
        player = nil
        loadedPath = nil
        isPlaying = false
        isLoaded = false
        duration = 0
        currentTime = 0
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        // `.common` rather than the default mode: while a menu is open or the
        // waveform is being scrolled, the run loop is in event-tracking mode and
        // a default-mode timer stops firing, freezing the playhead against audio
        // that is still playing.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension ChordAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.stopTimer()
            self.currentTime = 0
            self.player?.currentTime = 0
        }
    }
}

// MARK: - Waveform loader

@MainActor
final class WaveformLoader: ObservableObject {
    @Published var samples: [Float] = []
    @Published private(set) var isLoading = false
    private var loadedPath: String?

    func load(path: String) async {
        guard path != loadedPath else { return }
        loadedPath = path
        samples = []
        isLoading = true
        defer { isLoading = false }

        let capturedPath = path
        let result = await Task.detached(priority: .userInitiated) {
            WaveformLoader.extractSamples(from: capturedPath, targetCount: 2000)
        }.value
        guard capturedPath == loadedPath else { return }
        samples = result
    }

    func reset() {
        samples = []
        loadedPath = nil
    }

    nonisolated static func extractSamples(from path: String, targetCount: Int) -> [Float] {
        let url = URL(fileURLWithPath: path)
        guard let audioFile = try? AVAudioFile(forReading: url) else { return [] }
        let format = audioFile.processingFormat
        let totalFrames = Int64(audioFile.length)
        guard totalFrames > 0 else { return [] }
        let framesPerSample = max(1, Int(totalFrames) / targetCount)
        let chunkSize = AVAudioFrameCount(framesPerSample)
        let channelCount = Int(format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize),
              let channelData = buffer.floatChannelData else { return [] }
        var result: [Float] = []
        result.reserveCapacity(targetCount)
        while audioFile.framePosition < totalFrames {
            buffer.frameLength = 0
            do { try audioFile.read(into: buffer, frameCount: chunkSize) } catch { break }
            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0 else { break }
            var peak: Float = 0
            for frame in 0..<framesRead {
                for channel in 0..<channelCount {
                    let value = abs(channelData[channel][frame])
                    if value > peak { peak = value }
                }
            }
            result.append(peak)
        }
        return result
    }
}
