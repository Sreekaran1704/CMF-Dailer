import AVFoundation
import Foundation
import MediaPlayer

/// Media keys path A: become the Now Playing app and log every MPRemoteCommandCenter command.
final class RemoteCommandSniffer {
    private let center = MPRemoteCommandCenter.shared()
    private let log = SnifferLog.shared
    private(set) var nowPlaying = false

    func start() {
        let commands: [(String, MPRemoteCommand)] = [
            ("play", center.playCommand),
            ("pause", center.pauseCommand),
            ("togglePlayPause", center.togglePlayPauseCommand),
            ("stop", center.stopCommand),
            ("nextTrack", center.nextTrackCommand),
            ("previousTrack", center.previousTrackCommand),
            ("seekForward", center.seekForwardCommand),
            ("seekBackward", center.seekBackwardCommand),
        ]
        for (name, cmd) in commands {
            cmd.isEnabled = true
            cmd.addTarget { [log] ev in
                var fields: [String: Any] = ["event_uptime_s": ev.timestamp,
                                             "latency_ms": (ProcessInfo.processInfo.systemUptime - ev.timestamp) * 1000]
                if let seek = ev as? MPSeekCommandEvent { fields["seek_type"] = seek.type == .beginSeeking ? "begin" : "end" }
                log.write(kind: "capture", method: "remote_command", raw: name, fields: fields)
                return .success
            }
        }
        setNowPlaying(true)
    }

    func setNowPlaying(_ on: Bool, state: MPNowPlayingPlaybackState = .playing) {
        let info = MPNowPlayingInfoCenter.default()
        if on {
            info.nowPlayingInfo = [
                MPMediaItemPropertyTitle: "DialSniffer",
                MPMediaItemPropertyArtist: "DialHack",
                MPMediaItemPropertyPlaybackDuration: 3600.0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
                MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
            ]
            info.playbackState = state
        } else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
        }
        nowPlaying = on
        log.write(kind: "control", method: "now_playing", raw: on ? "on" : "off",
                  fields: ["state": on ? (state == .playing ? "playing" : "paused") : "stopped"])
    }
}

/// Plays digital silence so we can test whether Now Playing ownership needs real audio output.
final class SilentAudio {
    private var engine: AVAudioEngine?
    private(set) var playing = false

    func set(_ on: Bool) {
        if on == playing { return }
        if on {
            let engine = AVAudioEngine()
            let format = engine.outputNode.inputFormat(forBus: 0)
            let source = AVAudioSourceNode { _, _, frameCount, abl -> OSStatus in
                for buf in UnsafeMutableAudioBufferListPointer(abl) {
                    memset(buf.mData, 0, Int(buf.mDataByteSize))
                }
                _ = frameCount
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            do {
                try engine.start()
                self.engine = engine
                playing = true
            } catch {
                SnifferLog.shared.write(kind: "control", method: "silent_audio", raw: "error", fields: ["error": "\(error)"])
                return
            }
        } else {
            engine?.stop()
            engine = nil
            playing = false
        }
        SnifferLog.shared.write(kind: "control", method: "silent_audio", raw: on ? "on" : "off")
    }
}
