import Foundation

final class MusicPlaybackController {
    private let queue = DispatchQueue(label: "local.applemusiclyrics.playback-control")

    func seek(to position: TimeInterval, completion: @escaping () -> Void) {
        guard position.isFinite else { completion(); return }
        execute(["seek", String(max(0, position))], completion: completion)
    }

    func previousTrack(completion: @escaping () -> Void) {
        execute(["previous"], completion: completion)
    }

    func togglePlayPause(completion: @escaping () -> Void) {
        execute(["toggle"], completion: completion)
    }

    func nextTrack(completion: @escaping () -> Void) {
        execute(["next"], completion: completion)
    }

    private func execute(_ command: [String], completion: @escaping () -> Void) {
        queue.async {
            defer { DispatchQueue.main.async(execute: completion) }
            guard let executable = PlaybackMonitor.helperExecutableURL else {
                DiagnosticLogger.shared.warning("Playback control helper is unavailable")
                return
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
                }
            } catch {
                DiagnosticLogger.shared.warning("Playback control helper failed to start: \(error.localizedDescription)")
            }
        }
    }
}
