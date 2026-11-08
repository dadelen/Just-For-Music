import Foundation

final class MusicPlaybackController {
    enum Command: String {
        case previous, toggle, next, play, pause
        case cuePrevious = "cue-previous"
        case cueNext = "cue-next"
    }

    private let queue = DispatchQueue(label: "local.applemusiclyrics.playback-control")

    func seek(to position: TimeInterval, completion: @escaping () -> Void) {
        guard position.isFinite else { completion(); return }
        execute(["seek", String(max(0, position))]) { _ in completion() }
    }

    func perform(_ command: Command, completion: @escaping (Bool) -> Void) {
        execute([command.rawValue], completion: completion)
    }

    func perform(_ command: Command) async -> Bool {
        await withCheckedContinuation { continuation in
            perform(command) { continuation.resume(returning: $0) }
        }
    }

    private func execute(_ command: [String], completion: @escaping (Bool) -> Void) {
        queue.async {
            let succeeded = Self.run(command)
            DispatchQueue.main.async { completion(succeeded) }
        }
    }

    private static func run(_ command: [String]) -> Bool {
        guard let executable = PlaybackMonitor.helperExecutableURL else {
            DiagnosticLogger.shared.warning("Playback control helper is unavailable")
            return false
        }
        let process = Process()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["--control"] + command
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                DiagnosticLogger.shared.warning("Playback control \(command[0]) failed: \(message)")
                return false
            }
            DiagnosticLogger.shared.info("Playback control \(command[0]) succeeded")
            return true
        } catch {
            DiagnosticLogger.shared.warning("Playback control helper failed to start: \(error.localizedDescription)")
            return false
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
