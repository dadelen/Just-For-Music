// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Just-For-Music",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AppleMusicLyrics",
            path: "Sources/AppleMusicLyrics"
        ),
        .executableTarget(
            name: "AppleMusicLyricsPlaybackHelper",
            path: "Sources/PlaybackHelper"
        ),
        .testTarget(
            name: "AppleMusicLyricsTests",
            dependencies: ["AppleMusicLyrics"],
            path: "Tests/AppleMusicLyricsTests"
        )
    ]
)
