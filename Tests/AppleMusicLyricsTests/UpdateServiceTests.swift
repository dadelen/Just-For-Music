import Foundation
import XCTest
@testable import AppleMusicLyrics

final class UpdateServiceTests: XCTestCase {
    func testSemanticVersionComparison() throws {
        XCTAssertEqual(SemanticVersion("v1.5.1"), SemanticVersion("1.5.1"))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("1.5.1")), try XCTUnwrap(SemanticVersion("1.6.0")))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("1.9.9")), try XCTUnwrap(SemanticVersion("2.0.0")))
        XCTAssertNil(SemanticVersion("development"))
        XCTAssertNil(SemanticVersion("1.5"))
    }

    func testSelectsARM64DMGFromNewerRelease() throws {
        let service = UpdateService(currentVersion: "1.5.1")
        let update = try XCTUnwrap(service.availableUpdate(from: releaseJSON(tag: "v1.6.0")))

        XCTAssertEqual(update.version, SemanticVersion("1.6.0"))
        XCTAssertEqual(update.assetName, "Apple-Music-Lyrics-1.6.0-macos-arm64.dmg")
        XCTAssertEqual(update.checksumURL.lastPathComponent, "SHA256SUMS.txt")
    }

    func testRejectsReleaseWithoutARM64DMG() {
        let service = UpdateService(currentVersion: "1.5.1")
        let data = releaseJSON(tag: "v1.6.0", architecture: "universal")

        XCTAssertThrowsError(try service.availableUpdate(from: data)) { error in
            XCTAssertEqual(error as? UpdateServiceError, .downloadUnavailable)
        }
    }

    func testAcceptsRenamedAppleSiliconDiskImages() throws {
        let service = UpdateService(currentVersion: "1.5.1")
        for name in ["Just-For-Music-arm64.dmg", "Just-For-Music-1.6.0.dmg"] {
            let data = releaseJSON(tag: "v1.6.0", diskImageName: name)
            XCTAssertEqual(try service.availableUpdate(from: data)?.assetName, name)
        }
    }

    func testIgnoresCurrentAndPrereleaseVersions() throws {
        let service = UpdateService(currentVersion: "1.5.1")

        XCTAssertNil(try service.availableUpdate(from: releaseJSON(tag: "v1.5.1")))
        XCTAssertNil(try service.availableUpdate(
            from: releaseJSON(tag: "v1.6.0", prerelease: true)
        ))
    }

    func testRejectsUntrustedDownloadHost() throws {
        let service = UpdateService(currentVersion: "1.5.1")
        let data = releaseJSON(
            tag: "v1.6.0",
            downloadBaseURL: "https://downloads.example.com/releases/v1.6.0"
        )

        XCTAssertThrowsError(try service.availableUpdate(from: data)) { error in
            XCTAssertEqual(error as? UpdateServiceError, .downloadUnavailable)
        }
    }

    func testParsesChecksumForExactAssetName() {
        let expected = String(repeating: "a", count: 64)
        let contents = """
        \(String(repeating: "b", count: 64))  other.dmg
        \(expected)  Apple-Music-Lyrics-1.6.0-macos-arm64.dmg
        """

        XCTAssertEqual(
            UpdateService.expectedSHA256(
                in: contents,
                for: "Apple-Music-Lyrics-1.6.0-macos-arm64.dmg"
            ),
            expected
        )
        XCTAssertNil(UpdateService.expectedSHA256(in: contents, for: "missing.dmg"))
    }

    func testPublicGitHubUpdateAndVerifiedDownloadWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["JFM_UPDATE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set JFM_UPDATE_INTEGRATION=1 to check and download the public release")
        }
        let endpoint = try XCTUnwrap(URL(string: "https://api.github.com/repos/dadelen/Just-For-Music/releases/latest"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = UpdateService(currentVersion: "1.0.1", downloadsDirectory: directory, releaseURL: endpoint)
        let result = try await service.checkForUpdate()
        let update = try XCTUnwrap(result)
        let downloaded = try await service.download(update)
        XCTAssertEqual(downloaded.lastPathComponent, update.assetName)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: downloaded.path))

        let current = UpdateService(currentVersion: update.version.description, releaseURL: endpoint)
        let alreadyCurrent = try await current.checkForUpdate()
        XCTAssertNil(alreadyCurrent)
    }

    private func releaseJSON(
        tag: String,
        prerelease: Bool = false,
        downloadBaseURL: String? = nil,
        architecture: String = "arm64",
        diskImageName: String? = nil
    ) -> Data {
        let baseURL = downloadBaseURL
            ?? "https://github.com/Takpap/apple-music-lyrics/releases/download/\(tag)"
        let version = String(tag.drop(while: { $0 == "v" }))
        let assetPrefix = "Apple-Music-Lyrics-\(version)-macos-\(architecture)"
        let diskImageName = diskImageName ?? "\(assetPrefix).dmg"
        let object: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/Takpap/apple-music-lyrics/releases/tag/\(tag)",
            "draft": false,
            "prerelease": prerelease,
            "assets": [
                [
                    "name": "\(assetPrefix).zip",
                    "browser_download_url": "\(baseURL)/\(assetPrefix).zip"
                ],
                [
                    "name": diskImageName,
                    "browser_download_url": "\(baseURL)/\(diskImageName)"
                ],
                [
                    "name": "SHA256SUMS.txt",
                    "browser_download_url": "\(baseURL)/SHA256SUMS.txt"
                ]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}
