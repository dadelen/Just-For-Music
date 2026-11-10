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
    var controlErrors: [String?]? = nil
}

private let delimiter = "\u{1F}"
private let script = NSAppleScript(source: """
    property previousTrackKey : missing value
    property cachedTitle : ""
    property cachedArtist : ""
    property cachedAlbum : ""
    property cachedDuration : 0
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
        set trackKey to missing value
        try
            set trackKey to persistent ID of t
        end try
        if trackKey is missing value or trackKey is "" or trackKey is not equal to my previousTrackKey then
            set my cachedTitle to name of t
            set my cachedArtist to artist of t
            set my cachedAlbum to album of t
            set my cachedDuration to duration of t
            set my cachedBPM to 0
            try
                set my cachedBPM to (bpm of t) as integer
            end try
            set my previousTrackKey to trackKey
        end if
        set delim to "\(delimiter)"
        return my cachedTitle & delim & my cachedArtist & delim & my cachedAlbum & delim & (playbackState as text) & delim & (player position as text) & delim & (my cachedDuration as text) & delim & (my cachedBPM as text)
    end tell
    """)
private let encoder = JSONEncoder()
private var controlScripts: [String: NSAppleScript] = [:]

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

private func control(_ arguments: [String]) -> String? {
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
        guard let seconds = TimeInterval(arguments[1]), seconds.isFinite, seconds >= 0 else { return "Invalid seek position" }
        command = "set player position to \(seconds)"
    default:
        return "Unknown playback command"
    }
    guard let script = controlScripts[command] ?? NSAppleScript(source: """
        with timeout of 3 seconds
            tell application id "com.apple.Music"
                \(command)
            end tell
        end timeout
        """) else { return "Failed to create playback script" }
    // Seek values vary, so cache only the finite set of transport scripts.
    if arguments.count == 1 { controlScripts[command] = script }
    var errorInfo: NSDictionary?
    script.executeAndReturnError(&errorInfo)
    return errorInfo.map { $0[NSAppleScript.errorMessage] as? String ?? "Unable to control Music" }
}

private func cueTrack(_ direction: String) -> String {
    """
    pause
    \(direction)
    pause
    """
}

if CommandLine.arguments.dropFirst().first == "--control" {
    if let error = control(Array(CommandLine.arguments.dropFirst(2))) {
        FileHandle.standardError.write(Data(error.utf8))
        exit(1)
    }
    exit(0)
}

while let line = readLine() {
    autoreleasepool {
        if line == "sample" {
            write(sample())
        } else {
            let errors = line.components(separatedBy: "\t").map {
                control($0.split(separator: " ").map(String.init))
            }
            var response = sample()
            response.controlErrors = errors
            write(response)
        }
    }
}
