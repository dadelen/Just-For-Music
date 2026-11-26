import CommonCrypto
import Darwin
import Foundation

/// Reads the two player-only keys in NetEase Desktop's Chromium Local Storage
/// journal. The player records elapsed seconds here, including after a seek.
/// Storage format reference: https://github.com/DigHuang/SoftLive/blob/main/docs/subsystems/netease.md
final class NetEaseLocalPlayback {
    struct Progress: Equatable {
        let id: String
        let position: TimeInterval
        let duration: TimeInterval
    }

    struct Status {
        let id: String?
        let state: PlayerState
        let metadata: NetEaseQueueSong?
        let duration: TimeInterval?
    }

    struct Snapshot {
        let progress: Progress
        let writtenAt: Date
        let status: Status?
        let playbackAnchor: Date
        let hasRecordedProgress: Bool

        func position(at date: Date, state: PlayerState) -> TimeInterval {
            // Desktop writes a whole-second position. Interpolate only while
            // those reports are fresh, allowing for their one-second resolution.
            let age = max(0, date.timeIntervalSince(playbackAnchor))
            let elapsed = state == .playing ? min(age, Self.maximumReportAge) + 0.35 : 0
            return min(progress.duration, progress.position + elapsed)
        }

        static let maximumReportAge: TimeInterval = 3.6

        func isRecent(at date: Date) -> Bool {
            date.timeIntervalSince(playbackAnchor) <= Self.maximumReportAge
        }

        func state(at date: Date, menu: PlayerState?, audio: PlayerState?) -> PlayerState {
            if menu == .paused || (menu == nil && status?.state == .paused) { return .paused }
            if isRecent(at: date), menu == .playing || status?.state == .playing || audio != .paused { return .playing }
            return .paused
        }
    }

    private struct Write {
        let sequence: UInt64
        let value: Data
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    private struct FileRevision: Equatable {
        let identity: FileIdentity
        let modifiedAt: Date
        let changedAt: Date

        init(_ info: stat) {
            identity = FileIdentity(info)
            modifiedAt = Self.date(info.st_mtimespec)
            changedAt = Self.date(info.st_ctimespec)
        }

        private static func date(_ time: timespec) -> Date {
            Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
        }
    }

    private struct DirectoryListing {
        let revision: FileRevision
        let logURLs: [URL]
    }

    private struct Journal {
        let url: URL
        let directory: URL
        let size: Int
        let revision: FileRevision
        var date: Date { revision.modifiedAt }
    }

    private struct ScannedFile {
        let revision: FileRevision
        let size: Int
        let parsedOffset: Int
    }

    private struct StatusReport {
        let sequence: UInt64
        let date: Date
        let value: Status
        let resume: (sequence: UInt64, date: Date)?
    }

    private let directories: [URL]
    private var directory: URL?
    private var directoryIdentity: FileIdentity?
    private var listings: [URL: DirectoryListing] = [:]
    private var scanned: [URL: ScannedFile] = [:]
    private var progress: (write: Write, date: Date, value: Progress)?
    private var status: StatusReport?
    private var statusSequence: UInt64 = 0

    init(directories: [URL]? = nil) {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let path = "Documents/storage/CEFCache/Local Storage/leveldb"
        self.directories = directories ?? [
            library.appendingPathComponent("Application Support/com.netease.163music/" + path),
            library.appendingPathComponent("Containers/com.netease.163music/Data/" + path)
        ]
    }

    func read() -> Snapshot? {
        let files: [Journal]
        if let active = self.directory {
            let activeFiles = journals(in: active)
            if !activeFiles.isEmpty {
                files = activeFiles.sorted { $0.date > $1.date }
            } else {
                files = directories.flatMap(journals(in:)).sorted { $0.date > $1.date }
            }
        } else {
            files = directories.flatMap(journals(in:)).sorted { $0.date > $1.date }
        }
        guard let directory = files.first?.directory,
              let identity = listings[directory]?.revision.identity else { return nil }
        if self.directory != directory || directoryIdentity != identity {
            self.directory = directory
            directoryIdentity = identity
            scanned.removeAll()
            progress = nil
            status = nil
            statusSequence = 0
        }
        let journals = files.lazy.filter { $0.directory == directory }.prefix(2)
        for journal in journals.reversed() {
            let previous = scanned[journal.url]
            let sameFile = previous?.revision.identity == journal.revision.identity
            if let previous, previous.size == journal.size, previous.revision == journal.revision {
                continue
            }
            let startOffset: Int
            if let previous, sameFile, journal.size > previous.size, previous.parsedOffset <= journal.size {
                startOffset = previous.parsedOffset
            } else {
                startOffset = 0
            }
            guard let file = try? FileHandle(forReadingFrom: journal.url) else { continue }
            var openedInfo = stat()
            guard fstat(file.fileDescriptor, &openedInfo) == 0,
                  FileIdentity(openedInfo) == journal.revision.identity, openedInfo.st_size >= journal.size else {
                try? file.close()
                continue
            }
            if startOffset > 0 {
                do { try file.seek(toOffset: UInt64(startOffset)) }
                catch { try? file.close(); continue }
            }
            let expectedBytes = journal.size - startOffset
            let data = try? file.read(upToCount: expectedBytes)
            try? file.close()
            guard let data, data.count == expectedBytes else { continue }
            let parsed = Self.playerWrites(in: data, baseOffset: startOffset)
            scanned[journal.url] = ScannedFile(
                revision: journal.revision,
                size: journal.size,
                parsedOffset: parsed.nextOffset
            )
            let writes = parsed.writes
            if let report = writes["lastPlaying"], report.sequence > (progress?.write.sequence ?? 0),
               let value = Self.decodeProgress(report.value) {
                if let status, status.value.state == .paused, status.value.id == value.id, let previous = progress,
                   previous.write.sequence > status.sequence, previous.value.id == value.id {
                    let advance = value.position - previous.value.position
                    let elapsed = journal.date.timeIntervalSince(previous.date)
                    if advance > 0, abs(advance - elapsed) <= 1.2 {
                        // Two reports advancing in real time contradict an old pause.
                        self.status = nil
                    }
                }
                progress = (report, journal.date, value)
            }
            if let report = writes["playingInfo"], report.sequence > statusSequence,
               let value = Self.decodeStatus(report.value) {
                let resume: (UInt64, Date)?
                if value.state == .playing {
                    let wasPlayingThisTrack = status?.value.state == .playing && status?.value.id == value.id
                    resume = wasPlayingThisTrack ? status?.resume : (report.sequence, journal.date)
                } else {
                    resume = nil
                }
                status = StatusReport(sequence: report.sequence, date: journal.date, value: value, resume: resume)
                statusSequence = report.sequence
            }
        }
        let paths = Set(journals.map(\.url))
        scanned = scanned.filter { paths.contains($0.key) }
        if let status, let id = status.value.id, let duration = status.value.duration,
           status.sequence > (progress?.write.sequence ?? 0), id != progress?.value.id {
            // The player publishes the new track before it writes the first elapsed second.
            return Snapshot(progress: Progress(id: id, position: 0, duration: duration),
                            writtenAt: status.date, status: status.value, playbackAnchor: status.date,
                            hasRecordedProgress: false)
        }
        guard let progress else { return nil }
        let state = status.flatMap { $0.value.id == progress.value.id ? $0 : nil }
        let resumeDate = state?.resume.flatMap { $0.sequence > progress.write.sequence ? $0.date : nil }
        return Snapshot(progress: progress.value, writtenAt: progress.date, status: state?.value,
                        playbackAnchor: max(progress.date, resumeDate ?? progress.date), hasRecordedProgress: true)
    }

    private func journals(in directory: URL) -> [Journal] {
        guard let info = Self.fileInfo(at: directory, followsSymlinks: true),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            listings.removeValue(forKey: directory)
            return []
        }
        let revision = FileRevision(info)
        let logURLs: [URL]
        if let listing = listings[directory], listing.revision == revision {
            logURLs = listing.logURLs
        } else {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return [] }
            logURLs = files.filter { url in
                url.pathExtension == "log" && UInt64(url.deletingPathExtension().lastPathComponent) != nil
            }
            listings[directory] = DirectoryListing(revision: revision, logURLs: logURLs)
        }
        // The set of names changes on rotation. Appends only change the file itself.
        return logURLs.compactMap { url in
            guard let info = Self.fileInfo(at: url), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_size > 0, info.st_size <= 8 * 1024 * 1024 else { return nil }
            return Journal(url: url, directory: directory, size: Int(info.st_size), revision: FileRevision(info))
        }
    }

    private static func fileInfo(at url: URL, followsSymlinks: Bool = false) -> stat? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return followsSymlinks ? stat(path, &info) : lstat(path, &info)
        }
        return result == 0 ? info : nil
    }

    private static let progressKey = Data("_orpheus://orpheus\u{0}\u{1}lastPlaying".utf8)
    private static let statusKey = Data("_orpheus://orpheus\u{0}\u{1}playingInfo".utf8)

    /// LevelDB stores WriteBatches in 32 KiB blocks. Only complete batches are
    /// read, and only the exact keys from NetEase's player origin are decoded.
    private static func playerWrites(in data: Data, baseOffset: Int) -> (writes: [String: Write], nextOffset: Int) {
        let blockSize = 32_768
        var writes: [String: Write] = [:]
        var fragments: Data?
        var offset = 0
        var nextCompleteOffset = baseOffset
        while offset + 7 <= data.count {
            let absOffset = baseOffset + offset
            let end = ((absOffset / blockSize) + 1) * blockSize - baseOffset
            if offset + 7 > end {
                offset = end
                if fragments == nil { nextCompleteOffset = baseOffset + min(offset, data.count) }
                continue
            }
            let length = Int(data[offset + 4]) | Int(data[offset + 5]) << 8
            let kind = data[offset + 6]
            offset += 7
            if kind == 0 && length == 0 {
                offset = end
                if fragments == nil { nextCompleteOffset = baseOffset + min(offset, data.count) }
                continue
            }
            guard offset + length <= min(end, data.count) else { break }
            let bytes = data[offset..<(offset + length)]
            offset += length
            switch kind {
            case 1:
                collectWrites(from: bytes, into: &writes)
                fragments = nil
                nextCompleteOffset = baseOffset + offset
            case 2:
                fragments = Data(bytes)
            case 3:
                fragments?.append(bytes)
            case 4:
                if var complete = fragments {
                    complete.append(bytes)
                    collectWrites(from: complete, into: &writes)
                }
                fragments = nil
                nextCompleteOffset = baseOffset + offset
            default:
                fragments = nil
                nextCompleteOffset = baseOffset + offset
            }
        }
        return (writes, nextCompleteOffset)
    }

    private static func collectWrites(from batch: Data, into writes: inout [String: Write]) {
        guard batch.count >= 12 else { return }
        let start = batch.startIndex
        let sequence = batch[start..<(start + 8)].reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let count = batch[(start + 8)..<(start + 12)].reversed().reduce(0) { ($0 << 8) | Int($1) }
        guard count <= batch.count / 2, sequence <= UInt64.max - UInt64(count) else { return }
        var cursor = start + 12
        var recorded: [String: Write] = [:]
        for index in 0..<count {
            guard cursor < batch.endIndex else { return }
            let kind = batch[cursor]
            cursor += 1
            guard let key = field(in: batch, cursor: &cursor) else { return }
            if kind == 0 { continue }
            guard kind == 1, let value = field(in: batch, cursor: &cursor) else { return }
            if key == progressKey {
                recorded["lastPlaying"] = Write(sequence: sequence + UInt64(index), value: Data(value))
            } else if key == statusKey {
                recorded["playingInfo"] = Write(sequence: sequence + UInt64(index), value: Data(value))
            }
        }
        guard cursor == batch.endIndex else { return }
        writes.merge(recorded) { lhs, rhs in rhs.sequence > lhs.sequence ? rhs : lhs }
    }

    private static func field(in data: Data, cursor: inout Int) -> Data? {
        var length = 0
        for shift in stride(from: 0, through: 28, by: 7) {
            guard cursor < data.endIndex else { return nil }
            let byte = data[cursor]
            cursor += 1
            length |= Int(byte & 127) << shift
            if byte < 128 {
                guard length <= data.endIndex - cursor else { return nil }
                defer { cursor += length }
                return data[cursor..<(cursor + length)]
            }
        }
        return nil
    }

    private static func decodeProgress(_ value: Data) -> Progress? {
        guard let data = playerJSON(value), let id = songID(data["trackId"]) ?? songID(data["resourceId"]),
              let position = (data["current"] as? NSNumber)?.doubleValue, position.isFinite, position >= 0,
              let duration = (data["resourceDuration"] as? NSNumber)?.doubleValue, duration.isFinite,
              duration > 0, position <= duration else { return nil }
        return Progress(id: id, position: position, duration: duration)
    }

    private static func decodeStatus(_ value: Data) -> Status? {
        guard let data = playerJSON(value), let state = data["playingState"] as? Int, [1, 2].contains(state) else { return nil }
        let track = data["curTrack"] as? [String: Any]
        let metadata = (track?["track"] as? [String: Any] ?? track).flatMap(NetEaseQueueSong.parse)
        let id = songID(data["resourceTrackId"]) ?? metadata?.id
        let song = metadata?.id == id ? metadata : nil
        let duration = (data["resourceDuration"] as? NSNumber)?.doubleValue
        let validDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return Status(id: id, state: state == 2 ? .playing : .paused,
                      metadata: song, duration: song?.duration ?? validDuration)
    }

    private static func songID(_ value: Any?) -> String? {
        guard let raw = value as? String ?? (value as? NSNumber)?.stringValue,
              let number = Int64(raw), number > 0 else { return nil }
        return String(number)
    }

    private static func playerJSON(_ value: Data) -> [String: Any]? {
        guard value.first == 1, let input = Data(base64Encoded: value.dropFirst()),
              !input.isEmpty, input.count.isMultiple(of: kCCBlockSizeAES128) else { return nil }
        // Fixed format constant used by the desktop player for its playback fields.
        let key = Array(")(13daqP@ssw0rd~".utf8)
        let capacity = input.count + kCCBlockSizeAES128
        var plain = Data(count: capacity)
        var used = 0
        let status = plain.withUnsafeMutableBytes { output in
            input.withUnsafeBytes { inputBytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), key, key.count, nil,
                        inputBytes.baseAddress, input.count, output.baseAddress, capacity, &used)
            }
        }
        guard status == kCCSuccess else { return nil }
        return (try? JSONSerialization.jsonObject(with: plain.prefix(used))) as? [String: Any]
    }
}
