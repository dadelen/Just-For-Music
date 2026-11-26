import AppKit
import XCTest
@testable import AppleMusicLyrics

final class NetEaseLocalPlaybackTests: XCTestCase {
    // Synthetic NetEase storage values for a fictional song.
    private let listening = "069/oVMCeSo5SA11be+2Rc6XNvTxuKoJArilqkBVJLLCS3jHKbAkq5eY4Y6Q1z6lGCp34ySUy/6VBgVtsoHZaP5lD9FHdJCxPd6kRTGiFl4="
    private let afterSeek = "069/oVMCeSo5SA11be+2Rc6XNvTxuKoJArilqkBVJLLCS3jHKbAkq5eY4Y6Q1z6lGCp34ySUy/6VBgVtsoHZaPWf5/0yvsjNx79J+gE4MRE="
    private let paused = "grIQtS7vAw+jn2jJhWGm/YlkSwTYupP2uoX5cwCXQoDiU8LiSoe5LZDiLPqMGDm/"
    private let playing = "grIQtS7vAw+jn2jJhWGm/YlkSwTYupP2uoX5cwCXQoB5h8+e+hSYaC3bgZtzYXdE"

    func testLocalProgressSurvivesRotationAndTracksPausedSeek() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("000011.log")
        let second = directory.appendingPathComponent("000012.log")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func write(_ data: Data, to url: URL, at date: Date) throws {
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try write(record(20, "lastPlaying", listening) + record(21, "playingInfo", playing), to: first, at: now)
        let reader = NetEaseLocalPlayback(directories: [directory])
        let initial = try XCTUnwrap(reader.read())
        XCTAssertEqual(initial.progress.id, "123")
        XCTAssertEqual(initial.progress.duration, 240)
        XCTAssertEqual(initial.state(at: now, menu: nil, audio: .paused), .playing)
        XCTAssertEqual(initial.position(at: now.addingTimeInterval(1), state: .playing), 13.35, accuracy: 0.001)

        let cut = now.addingTimeInterval(8)
        let seek = record(24, "lastPlaying", afterSeek)
        try write(record(23, "playingInfo", paused) + seek.dropLast(), to: second, at: cut)
        let partial = try XCTUnwrap(reader.read())
        XCTAssertEqual(partial.progress.position, 12)
        XCTAssertEqual(partial.state(at: cut, menu: nil, audio: .playing), .paused)

        try write(record(23, "playingInfo", paused) + seek, to: second, at: cut)
        let sought = try XCTUnwrap(reader.read())
        XCTAssertEqual(sought.position(at: cut.addingTimeInterval(2), state: .paused), 75)

        let finalTime = cut.addingTimeInterval(10)
        XCTAssertEqual(sought.state(at: finalTime, menu: .playing, audio: .playing), .paused)
    }

    func testResumeAndTrackChangeUsePlayingInfoBeforeProgressIsWritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("000013.log")
        let original = Date(timeIntervalSince1970: 1_700_000_000)
        var contents = record(20, "lastPlaying", listening) + record(21, "playingInfo", paused)
        func save(at date: Date) throws {
            try contents.write(to: journal)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: journal.path)
        }
        let reader = NetEaseLocalPlayback(directories: [directory])
        try save(at: original)
        XCTAssertEqual(reader.read()?.state(at: original, menu: nil, audio: nil), .paused)

        let resume = original.addingTimeInterval(60)
        contents.append(record(22, "playingInfo", playing))
        try save(at: resume)
        let resumed = try XCTUnwrap(reader.read())
        XCTAssertEqual(resumed.writtenAt, original)
        XCTAssertEqual(resumed.state(at: resume, menu: nil, audio: nil), .playing)
        XCTAssertEqual(resumed.position(at: resume, state: .playing), 12.35, accuracy: 0.001)

        let change = resume.addingTimeInterval(1)
        let nextStatus = "grIQtS7vAw+jn2jJhWGm/X2jn73cSTjxu7T8iwJiF+YBJ7QwxAQyqOOYlMYscMKX94BfA2JFa48ok00qPIlcA+xB4smjQT0NBZxLKjD1ZgU="
        contents.append(record(23, "playingInfo", nextStatus))
        try save(at: change)
        let changed = try XCTUnwrap(reader.read())
        XCTAssertEqual(changed.progress.id, "456")
        XCTAssertEqual(changed.progress.position, 0)
        XCTAssertFalse(changed.hasRecordedProgress)

        let nextProgress = "UnpVlLHrAck60OUzHaLR06CS8HCHOJUo4Ufi0GkHempGS49cwVZJqGiKVdhcGzqKQRp/Q8ZaIIh9JXeKB3mQbQijmlZxc5tx7HrcUkB8SBE="
        contents.append(record(24, "lastPlaying", nextProgress))
        try save(at: change.addingTimeInterval(2))
        let measured = try XCTUnwrap(reader.read())
        XCTAssertEqual(measured.progress.id, "456")
        XCTAssertEqual(measured.progress.position, 2)
        XCTAssertTrue(measured.hasRecordedProgress)
    }

    func testStalePauseIsNotReappliedWhenTheJournalGrows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("000014.log")
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let reader = NetEaseLocalPlayback(directories: [directory])
        var contents = record(20, "lastPlaying", listening) + record(21, "playingInfo", paused)
        func read(at seconds: TimeInterval) throws -> PlayerState? {
            let date = start.addingTimeInterval(seconds)
            try contents.write(to: journal)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: journal.path)
            return reader.read()?.state(at: date, menu: nil, audio: nil)
        }
        XCTAssertEqual(try read(at: 0), .paused)
        contents.append(record(22, "lastPlaying", listening))
        XCTAssertEqual(try read(at: 1), .paused)
        contents.append(record(23, "lastPlaying", afterSeek))
        XCTAssertEqual(try read(at: 64), .playing)
        contents.append(record(24, "unrelated", paused))
        XCTAssertEqual(try read(at: 65), .playing)
    }

    func testClientCommandPayloadsAreScopedToThePlayerScheme() throws {
        func payload(_ command: NetEaseClientCommand) throws -> [String: Any] {
            let url = try XCTUnwrap(command.url)
            XCTAssertEqual(url.scheme, "orpheus")
            let encoded = String(url.absoluteString.dropFirst("orpheus://".count))
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(try payload(.previous)["cmd"] as? String, "previous")
        XCTAssertEqual(try payload(.next)["cmd"] as? String, "next")
        XCTAssertEqual(try payload(.resume)["cmd"] as? String, "resume")
        XCTAssertEqual(try payload(.pause)["cmd"] as? String, "pause")
        XCTAssertEqual(try payload(.seek(143.5))["value"] as? Double, 143.5)
        XCTAssertNil(NetEaseClientCommand.seek(.infinity).url)
        XCTAssertNil(NetEaseClientCommand.seek(-1).url)
    }

    func testWholeSecondReportsKeepContinuousTimeAndAllowRealSeeks() {
        var clock = NetEasePlaybackClock()
        var track = NetEaseBarTrack(title: "Song", artist: "", id: "123", position: 20.35, duration: 240)
        XCTAssertEqual(clock.update(track: track, state: .playing, at: 100), 20.35)
        // A real NetEase trace alternated between almost a second behind the
        // interpolated position and almost a second ahead on successive writes.
        for (index, observed) in [21.38, 21.41, 24.31, 23.37, 26.32].enumerated() {
            let elapsed = Double(index + 1)
            track.position = observed
            XCTAssertEqual(clock.update(track: track, state: .playing, at: 100 + elapsed), 20.35 + elapsed, accuracy: 0.0001)
        }
        track.position = 11
        XCTAssertEqual(clock.update(track: track, state: .playing, at: 106), 11)
        track.position = 75
        XCTAssertEqual(clock.update(track: track, state: .playing, at: 107), 75)
        track.id = "456"
        track.position = 0.2
        XCTAssertEqual(clock.update(track: track, state: .playing, at: 108), 0.2)
    }

    func testPauseAndMissingReportsHoldTheDisplayButPausedSeekCanMoveIt() {
        var clock = NetEasePlaybackClock()
        var track = NetEaseBarTrack(title: "Song", artist: "", id: "123", position: 15.4, duration: 240)
        _ = clock.update(track: track, state: .playing, at: 40)
        track.position = 16
        XCTAssertEqual(clock.update(track: track, state: .paused, at: 41), 16.4, accuracy: 0.0001)
        XCTAssertEqual(clock.update(track: track, state: .paused, at: 42), 16.4, accuracy: 0.0001)
        track.position = 15
        XCTAssertEqual(clock.update(track: track, state: .paused, at: 43), 15)
        _ = clock.update(track: track, state: .playing, at: 44)
        XCTAssertEqual(clock.update(track: track, state: .paused, at: 47, holdsLastPosition: true), 18)
        XCTAssertEqual(clock.update(track: track, state: .paused, at: 49, holdsLastPosition: true), 18)
    }

    func testClockUsesOverlappingProgressReportsWithoutJumpingBetweenLyrics() {
        var clock = NetEasePlaybackClock()
        var track = NetEaseBarTrack(title: "Song", artist: "", id: "123", position: 20, duration: 240)
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        func report(writtenAt seconds: TimeInterval, position: Double) -> NetEasePlaybackClock.ProgressReport {
            .init(writtenAt: origin.addingTimeInterval(seconds), phaseStart: position - seconds)
        }
        // Relative write times and whole-second positions from a playing client.
        let writes: [(time: Double, position: Double)] = [
            (0, 20), (1.969, 21), (3.002, 23), (4.999, 25),
            (6.999, 27), (8.967, 28), (9.999, 30), (11.999, 32)
        ]
        var sample = report(writtenAt: 0, position: 20)
        var position = clock.update(track: track, state: .playing, at: 0, progressReport: sample)
        var index = 1
        for tick in 1...120 {
            let time = Double(tick) / 10
            if index < writes.count, time >= writes[index].time {
                let write = writes[index]
                sample = report(writtenAt: write.time, position: write.position)
                index += 1
            }
            track.position = time + sample.phaseStart + 0.35
            let predicted = position + 0.1 * clock.rate
            position = clock.update(track: track, state: .playing, at: time, progressReport: sample)
            XCTAssertEqual(position, predicted, accuracy: 0.0001)
            if tick == 20 { XCTAssertLessThan(clock.rate, 0.9) }
        }
        // The measured reports constrain elapsed position to 32.001...32.231.
        XCTAssertEqual(position, 32.116, accuracy: 0.01)

        track.position = 80
        let jumped = clock.update(track: track, state: .playing, at: 12.1,
                                  progressReport: report(writtenAt: 12.1, position: 80))
        XCTAssertEqual(jumped, 80.6, accuracy: 0.0001)
        XCTAssertEqual(clock.rate, 1)
    }

    @MainActor
    func testRunningClientFollowsPauseSeekAndResumeWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["JFM_NETEASE_CONTROL_INTEGRATION"] == "1" else {
            throw XCTSkip("Set JFM_NETEASE_CONTROL_INTEGRATION=1 to test pause, seek and resume of the playing NetEase song")
        }
        _ = NSApplication.shared
        let backend = NetEasePlayback()
        var track: TrackInfo?
        backend.onUpdate = { update in
            if case .track(let current) = update { track = current }
        }
        backend.start()
        defer { backend.stop() }

        func waitFor(_ condition: (TrackInfo) -> Bool) async throws -> TrackInfo {
            let deadline = ProcessInfo.processInfo.systemUptime + 16
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let track, condition(track) { return track }
                try await Task.sleep(nanoseconds: 60_000_000)
            }
            throw CocoaError(.fileReadUnknown)
        }
        func send(_ arguments: [String]) async -> Bool {
            await withCheckedContinuation { continuation in
                backend.performControl(arguments) { continuation.resume(returning: $0) }
            }
        }
        let original = try await waitFor {
            $0.state == .playing && $0.canSeek && $0.position < $0.duration - 10
        }
        let pauseRequestTime = ProcessInfo.processInfo.systemUptime
        let pauseSent = await send(["toggle"])
        let pauseDelivery = ProcessInfo.processInfo.systemUptime - pauseRequestTime
        XCTAssertTrue(pauseSent)
        var originalPosition = original.position
        do {
            let stopped = try await waitFor { $0.state == .paused && $0.identityKey == original.identityKey }
            print("NetEase pause: delivery \(pauseDelivery)s, playback state \(ProcessInfo.processInfo.systemUptime - pauseRequestTime)s")
            originalPosition = stopped.position
            let target = (originalPosition + (originalPosition > 12 ? -10 : 8)).rounded(.down)
            let seekSucceeded = await send(["seek", String(target)])
            XCTAssertTrue(seekSucceeded)
            let sought = try await waitFor {
                $0.state == .paused && $0.identityKey == original.identityKey && abs($0.position - target) < 2
            }
            XCTAssertLessThan(abs(sought.position - target), 2)
        } catch {
            if track?.identityKey == original.identityKey {
                _ = await send(["seek", String(originalPosition)])
                _ = await send(["play"])
            }
            throw error
        }
        let restored = await send(["seek", String(originalPosition)])
        XCTAssertTrue(restored)
        let resumeRequestTime = ProcessInfo.processInfo.systemUptime
        let resumeSent = await send(["toggle"])
        let resumeDelivery = ProcessInfo.processInfo.systemUptime - resumeRequestTime
        XCTAssertTrue(resumeSent)
        _ = try await waitFor { $0.state == .playing && $0.identityKey == original.identityKey }
        print("NetEase resume: delivery \(resumeDelivery)s, playback state \(ProcessInfo.processInfo.systemUptime - resumeRequestTime)s")
    }

    func testIncrementalJournalReadsSurviveBlockBoundariesAndTruncatedRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("000015.log")
        let reader = NetEaseLocalPlayback(directories: [directory])
        let start = Date(timeIntervalSinceReferenceDate: 200)
        var contents = record(10, "lastPlaying", listening) + record(11, "playingInfo", playing)
        // Pad block 0 up to the 32 KiB LevelDB block boundary, leaving a 4-byte zero trailer.
        var sequence: UInt64 = 12
        while 32_768 - contents.count >= 260 {
            contents.append(record(sequence, "unrelated", String(repeating: "x", count: 200)))
            sequence += 1
        }
        let remainingInBlock = 32_768 - contents.count
        if remainingInBlock >= 7 {
            let filler = String(repeating: "y", count: max(0, remainingInBlock - 40))
            let chunk = record(sequence, "unrelated", filler)
            sequence += 1
            if contents.count + chunk.count <= 32_768 {
                contents.append(chunk)
            }
        }
        if contents.count < 32_768 {
            contents.append(Data(repeating: 0, count: 32_768 - contents.count))
        }
        contents.append(record(sequence, "unrelated", "block1"))
        sequence += 1
        func write(at offset: TimeInterval) throws {
            let date = start.addingTimeInterval(offset)
            try contents.write(to: journal)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: journal.path)
        }

        try write(at: 0)
        let initial = try XCTUnwrap(reader.read())
        XCTAssertEqual(initial.progress.position, 12)
        XCTAssertEqual(initial.state(at: start, menu: nil, audio: nil), .playing)

        let nextRecord = record(sequence, "lastPlaying", afterSeek)
        let split = nextRecord.count / 2
        contents.append(nextRecord.prefix(split))
        try write(at: 1)
        let truncated = try XCTUnwrap(reader.read())
        XCTAssertEqual(truncated.progress.position, 12)

        contents.append(nextRecord.dropFirst(split))
        contents.append(record(sequence + 1, "playingInfo", paused))
        try write(at: 2)
        let completed = try XCTUnwrap(reader.read())
        XCTAssertEqual(completed.progress.position, 75)
        XCTAssertEqual(completed.state(at: start.addingTimeInterval(2), menu: nil, audio: nil), .paused)
    }

    func testRecreatedJournalDirectoryAcceptsNewSequenceNumbers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = folder.appendingPathComponent("leveldb", isDirectory: true)
        let journal = directory.appendingPathComponent("000003.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let reader = NetEaseLocalPlayback(directories: [directory])
        try (record(90, "lastPlaying", listening) + record(91, "playingInfo", paused)).write(to: journal)
        XCTAssertEqual(reader.read()?.progress.position, 12)
        XCTAssertEqual(reader.read()?.status?.state, .paused)

        try FileManager.default.moveItem(at: directory, to: folder.appendingPathComponent("old", isDirectory: true))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try (record(1, "lastPlaying", afterSeek) + record(2, "playingInfo", playing)).write(to: journal)
        XCTAssertEqual(reader.read()?.progress.position, 75)
        XCTAssertEqual(reader.read()?.status?.state, .playing)
    }

    private func record(_ sequence: UInt64, _ key: String, _ value: String) -> Data {
        let key = Array("_orpheus://orpheus\u{0}\u{1}".utf8) + Array(key.utf8)
        let value = [UInt8(1)] + value.utf8
        var batch = (0..<8).map { UInt8(truncatingIfNeeded: sequence >> (8 * $0)) }
        batch += [1, 0, 0, 0, 1, UInt8(key.count)] + key
        if value.count >= 128 {
            batch += [UInt8(value.count % 128 + 128), UInt8(value.count / 128)]
        } else {
            batch.append(UInt8(value.count))
        }
        batch += value
        return Data([0, 0, 0, 0, UInt8(batch.count % 256), UInt8(batch.count / 256), 1] + batch)
    }
}
