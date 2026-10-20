import AVFoundation
import Foundation
import MediaPlayer

/// Capture layer, presses: MPRemoteCommandCenter (the only path that received dial presses in
/// Phase 0). Never posts media keys itself, so nothing can loop back into this capture.
final class MediaKeyCapture {
    /// Called on the main queue.
    var onRaw: ((RawInput, Double) -> Void)?

    private let center = MPRemoteCommandCenter.shared()
    let silence = SilentAudio()

    func start() {
        let commands: [(MPRemoteCommand, RawInput)] = [
            (center.playCommand, .playPause("play")),
            (center.pauseCommand, .playPause("pause")),
            (center.togglePlayPauseCommand, .playPause("togglePlayPause")),
            (center.nextTrackCommand, .nextTrack),
            (center.previousTrackCommand, .previousTrack),
        ]
        for (cmd, raw) in commands {
            cmd.isEnabled = true
            cmd.addTarget { [weak self] _ in
                let t = monoMs()
                DispatchQueue.main.async { self?.onRaw?(raw, t) }
                return .success
            }
        }
        setClaim(false, keepNowPlaying: false)
    }

    /// In hijacking modes DialHack claims Now Playing ("playing", optionally with silent audio) so
    /// presses come here. In passthrough it advertises "paused" so music apps take precedence.
    func setClaim(_ claim: Bool, keepNowPlaying: Bool) {
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "DialHack",
            MPMediaItemPropertyArtist: claim ? "Dial active" : "Passthrough",
            MPNowPlayingInfoPropertyPlaybackRate: claim ? 1.0 : 0.0,
        ]
        info.playbackState = claim ? .playing : .paused
        silence.set(claim && keepNowPlaying)
    }
}

/// Digital silence through AVAudioEngine, to hold Now Playing while a hijacking mode is active.
///
/// AVAudioEngine stops by itself when the audio route changes (buds reconnecting, output switching).
/// A stopped engine meant DialHack silently lost Now Playing, and dial presses went to whichever app
/// played media last (user report, 2026-10-20). So: track the *desired* state, rebuild on configuration
/// changes, and re-check every few seconds.
final class SilentAudio {
    private var engine: AVAudioEngine?
    private var wanted = false
    private var observer: NSObjectProtocol?
    private var health: Timer?
    private(set) var restarts = 0

    var isPlaying: Bool { engine?.isRunning ?? false }

    func set(_ on: Bool) {
        wanted = on
        if on {
            if !isPlaying { rebuild() }
            if health == nil {
                health = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    guard let self, self.wanted, !self.isPlaying else { return }
                    self.restarts += 1
                    self.rebuild()
                }
            }
        } else {
            health?.invalidate()
            health = nil
            teardown()
        }
    }

    private func teardown() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        engine?.stop()
        engine = nil
    }

    private func rebuild() {
        teardown()
        let e = AVAudioEngine()
        let format = e.outputNode.inputFormat(forBus: 0)
        let source = AVAudioSourceNode { _, _, _, abl -> OSStatus in
            for buf in UnsafeMutableAudioBufferListPointer(abl) { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
            return noErr
        }
        e.attach(source)
        e.connect(source, to: e.mainMixerNode, format: format)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e,
                                                          queue: .main) { [weak self] _ in
            guard let self, self.wanted else { return }
            self.restarts += 1
            self.rebuild()
        }
        if (try? e.start()) != nil { engine = e }
    }
}
