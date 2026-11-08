import AppKit
import Foundation

#if !arch(arm64)
#error("Apple Music Lyrics Playback Helper requires Apple silicon (arm64).")
#endif

private struct Response: Codable {
    let kind: String
    let title: String?
    let artist: String?
    let album: String?
    let duration: TimeInterval?
    let position: TimeInterval?
    let state: String?
    let error: String?
}

private let delimiter = "\u{1F}"
private let script = NSAppleScript(source: """
    tell application "Music"
        if player state is stopped then
            return "STOPPED"
        end if
        set t to current track
        set delim to "\(delimiter)"
        return (name of t) & delim & (artist of t) & delim & (album of t) & delim & (player state as text) & delim & (player position as text) & delim & (duration of t as text)
    end tell
    """)
private let encoder = JSONEncoder()

private func sample() -> Response {
    guard !NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.Music"
    ).isEmpty else {
        return Response(
            kind: "musicNotRunning", title: nil, artist: nil, album: nil,
            duration: nil, position: nil, state: nil, error: nil
        )
    }
    guard let script else {
        return Response(
            kind: "error", title: nil, artist: nil, album: nil,
            duration: nil, position: nil, state: nil,
            error: "Failed to create AppleScript."
        )
    }

    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
        let message = errorInfo[NSAppleScript.errorMessage] as? String
            ?? errorInfo.description
        return Response(
            kind: "error", title: nil, artist: nil, album: nil,
            duration: nil, position: nil, state: nil, error: message
        )
    }

    let value = (result.stringValue ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value != "STOPPED" else {
        return Response(
            kind: "stopped", title: nil, artist: nil, album: nil,
            duration: nil, position: nil, state: nil, error: nil
        )
    }

    let fields = value.components(separatedBy: delimiter)
    guard fields.count >= 6 else {
        return Response(
            kind: "error", title: nil, artist: nil, album: nil,
            duration: nil, position: nil, state: nil,
            error: "Unexpected Music response: \(value)"
        )
    }
    return Response(
        kind: "track",
        title: fields[0],
        artist: fields[1],
        album: fields[2],
        duration: TimeInterval(fields[5].replacingOccurrences(of: ",", with: ".")),
        position: TimeInterval(fields[4].replacingOccurrences(of: ",", with: ".")),
        state: fields[3],
        error: nil
    )
}

private func write(_ response: Response) {
    guard var data = try? encoder.encode(response) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

private func control(_ arguments: [String]) -> Int32 {
    let command: String
    switch arguments.first {
    case "previous" where arguments.count == 1: command = "previous track"
    case "toggle" where arguments.count == 1: command = "playpause"
    case "next" where arguments.count == 1: command = "next track"
    case "seek" where arguments.count == 2:
        guard let seconds = TimeInterval(arguments[1]), seconds.isFinite, seconds >= 0 else { return 64 }
        command = "set player position to \(seconds)"
    default:
        return 64
    }
    guard let script = NSAppleScript(source: """
        with timeout of 3 seconds
            tell application "Music" to \(command)
        end timeout
        """) else { return 1 }
    var errorInfo: NSDictionary?
    script.executeAndReturnError(&errorInfo)
    if let errorInfo {
        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unable to control Music"
        FileHandle.standardError.write(Data(message.utf8))
        return 1
    }
    return 0
}

if CommandLine.arguments.dropFirst().first == "--control" {
    exit(control(Array(CommandLine.arguments.dropFirst(2))))
}

while readLine() != nil {
    autoreleasepool {
        write(sample())
    }
}
