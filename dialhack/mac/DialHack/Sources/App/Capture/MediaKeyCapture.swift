import AVFoundation
import Foundation
import MediaPlayer

/// Capture layer, presses: MPRemoteCommandCenter (the only path that received dial presses in
/// Phase 0). Never posts media keys itself, so nothing can loop back into this capture.
final class MediaKeyCapture {
    /// Called on the main queue.
    var onRaw: ((RawInput, Double) -> Void)?

    private let center = MPRemoteCommandCenter.shared()
    private let silence = SilentAudio()

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
final class SilentAudio {
    private var engine: AVAudioEngine?

    func set(_ on: Bool) {
        if on == (engine != nil) { return }
        guard on else {
            engine?.stop()
            engine = nil
            return
        }
        let e = AVAudioEngine()
        let format = e.outputNode.inputFormat(forBus: 0)
        let source = AVAudioSourceNode { _, _, _, abl -> OSStatus in
            for buf in UnsafeMutableAudioBufferListPointer(abl) { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
            return noErr
        }
        e.attach(source)
        e.connect(source, to: e.mainMixerNode, format: format)
        if (try? e.start()) != nil { engine = e }
    }
}
