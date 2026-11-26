import Foundation

@MainActor
final class MusicPlaybackController {
    enum Command: String {
        case previous, toggle, next, play, pause
    }

    private let monitor: PlaybackTransport

    init(monitor: PlaybackTransport) {
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
    static func toggle(
        startingAt track: TrackInfo,
        moveNeedle: (Bool) async -> Void,
        setPlaybackState: (PlayerState) async -> Void,
        currentTrack: () -> TrackInfo?
    ) async {
        let target: PlayerState = track.state == .playing ? .paused : .playing
        await moveNeedle(target == .playing)
        guard !Task.isCancelled, let current = currentTrack(),
              current.identityKey == track.identityKey, current.state == track.state else { return }
        await setPlaybackState(target)
    }
}
