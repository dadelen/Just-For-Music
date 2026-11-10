import Foundation

final class MusicPlaybackController {
    enum Command: String {
        case previous, toggle, next, play, pause
        case cuePrevious = "cue-previous"
        case cueNext = "cue-next"
    }

    private let monitor: PlaybackMonitor

    init(monitor: PlaybackMonitor) {
        self.monitor = monitor
    }

    func seek(to position: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard position.isFinite else { completion(false); return }
        monitor.performControl(["seek", String(max(0, position))], completion: completion)
    }

    func perform(_ command: Command, completion: @escaping (Bool) -> Void = { _ in }) {
        monitor.performControl([command.rawValue], completion: completion)
    }

    func perform(_ command: Command) async -> Bool {
        await withCheckedContinuation { continuation in
            perform(command) { continuation.resume(returning: $0) }
        }
    }
}

@MainActor
enum NeedlePlayback {
    static func run(
        _ command: MusicPlaybackController.Command,
        startingAt track: TrackInfo,
        moveNeedle: (Bool) async -> Void,
        perform: (MusicPlaybackController.Command) async -> Bool,
        currentTrack: () -> TrackInfo?
    ) async {
        let wasPlaying = track.state == .playing
        let willPlay = command == .toggle && !wasPlaying
        await moveNeedle(willPlay)
        guard matches(track, currentTrack()) else { return }

        if command == .toggle {
            _ = await perform(willPlay ? .play : .pause)
            return
        }
        let switched = await perform(command == .previous ? .cuePrevious : .cueNext)
        guard switched, wasPlaying, let queuedTrack = currentTrack(), queuedTrack.state == .paused else { return }
        await moveNeedle(true)
        guard matches(queuedTrack, currentTrack()) else { return }
        _ = await perform(.play)
    }

    private static func matches(_ expected: TrackInfo, _ current: TrackInfo?) -> Bool {
        !Task.isCancelled && current?.identityKey == expected.identityKey && current?.state == expected.state
    }
}
