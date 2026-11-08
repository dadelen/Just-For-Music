import AppKit
import Foundation

#if !arch(arm64)
#error("Just-For-Music playback helper requires Apple silicon (arm64).")
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
    var bpm: Int? = nil
}

private let delimiter = "\u{1F}"
private let script = NSAppleScript(source: """
    property previousTrackKey : missing value
    property cachedBPM : 0

    if application id "com.apple.Music" is not running then
        set my previousTrackKey to missing value
        return "MUSIC_NOT_RUNNING"
    end if
    tell application id "com.apple.Music"
        set playbackState to player state
        if playbackState is stopped then
            set my previousTrackKey to missing value
            return "STOPPED"
        end if
        set t to current track
        set trackTitle to name of t
        set trackArtist to artist of t
        set trackAlbum to album of t
        set trackDuration to duration of t
        set trackKey to {trackTitle, trackArtist, trackAlbum, trackDuration}
        if trackKey is not equal to my previousTrackKey then
            set my previousTrackKey to trackKey
            set my cachedBPM to 0
            try
                set my cachedBPM to (bpm of t) as integer
            end try
        end if
        set delim to "\(delimiter)"
        return trackTitle & delim & trackArtist & delim & trackAlbum & delim & (playbackState as text) & delim & (player position as text) & delim & (trackDuration as text) & delim & (my cachedBPM as text)
    end tell
    """)
private let encoder = JSONEncoder()

private func sample() -> Response {
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
    if value == "MUSIC_NOT_RUNNING" {
        return Response(
            kind: "musicNotRunning", title: nil, artist: nil, album: nil,
            duration: nil, position: nil, state: nil, error: nil
        )
    }
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
    let bpm = fields.count > 6 ? Int(fields[6]).flatMap { $0 > 0 ? $0 : nil } : nil
    return Response(
        kind: "track",
        title: fields[0],
        artist: fields[1],
        album: fields[2],
        duration: TimeInterval(fields[5].replacingOccurrences(of: ",", with: ".")),
        position: TimeInterval(fields[4].replacingOccurrences(of: ",", with: ".")),
        state: fields[3],
        error: nil,
        bpm: bpm
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
    case "play" where arguments.count == 1: command = "play"
    case "pause" where arguments.count == 1: command = "pause"
    case "cue-previous" where arguments.count == 1: command = cueTrack("previous track")
    case "cue-next" where arguments.count == 1: command = cueTrack("next track")
    case "seek" where arguments.count == 2:
        guard let seconds = TimeInterval(arguments[1]), seconds.isFinite, seconds >= 0 else { return 64 }
        command = "set player position to \(seconds)"
    default:
        return 64
    }
    guard let script = NSAppleScript(source: """
        with timeout of 3 seconds
            tell application "Music"
                \(command)
            end tell
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

private func cueTrack(_ direction: String) -> String {
    """
    pause
    \(direction)
    pause
    """
}

if CommandLine.arguments.dropFirst().first == "--control" {
    exit(control(Array(CommandLine.arguments.dropFirst(2))))
}

while readLine() != nil {
    autoreleasepool {
        write(sample())
    }
}
