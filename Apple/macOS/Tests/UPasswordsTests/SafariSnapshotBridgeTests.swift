import Foundation
import Testing

@testable import UPasswords

@Suite
struct SafariSnapshotBridgeTests {
    @Test
    func removesBothSnapshotsAndPreservesOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let safari = root.appendingPathComponent("Safari", isDirectory: true)
        let credentialProvider = root.appendingPathComponent("CredentialProvider", isDirectory: true)
        let unrelated = root.appendingPathComponent("Other", isDirectory: true)
        for directory in [safari, credentialProvider, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: directory.appendingPathComponent("snapshot"))
        }

        try SafariSnapshotBridge.removeSnapshots(in: root)

        #expect(!FileManager.default.fileExists(atPath: safari.path))
        #expect(!FileManager.default.fileExists(atPath: credentialProvider.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test
    func missingSnapshotsAreNotAnError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try SafariSnapshotBridge.removeSnapshots(in: root)
    }

    @Test
    func continuesAfterOneRemovalFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let safari = root.appendingPathComponent("Safari", isDirectory: true)
        let credentialProvider = root.appendingPathComponent("CredentialProvider", isDirectory: true)
        try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: credentialProvider, withIntermediateDirectories: true)

        #expect(throws: CocoaError.self) {
            try SafariSnapshotBridge.removeSnapshots(in: root) { url in
                if url.lastPathComponent == "Safari" { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            }
        }

        #expect(FileManager.default.fileExists(atPath: safari.path))
        #expect(!FileManager.default.fileExists(atPath: credentialProvider.path))
    }
}
