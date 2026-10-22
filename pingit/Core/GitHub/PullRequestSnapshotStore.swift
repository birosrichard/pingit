import Darwin
import Foundation

struct PullRequestSnapshotStore: Sendable {
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumEntries = 20_000
    enum Failure: Error { case invalidSnapshot, tooLarge, unavailable }
    let read: @Sendable () throws -> Data?
    let write: @Sendable (Data) throws -> Void

    static var applicationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.biros.pingit/ChangeDetection", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    init(url: URL = Self.applicationURL) {
        read = {
            try Self.removeOrphanedWrites(in: url.deletingLastPathComponent())
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= Self.maximumBytes else { throw Failure.tooLarge }
            return try Data(contentsOf: url)
        }
        write = { data in try Self.atomicWrite(data, to: url) }
    }

    init(read: @escaping @Sendable () throws -> Data?, write: @escaping @Sendable (Data) throws -> Void) {
        self.read = read
        self.write = write
    }

    func load() throws -> PullRequestChangeSnapshot? {
        guard let data = try read() else { return nil }
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        // Invalid/incompatible content is a new baseline, never historical activity.
        guard var value = try? JSONDecoder().decode(PullRequestChangeSnapshot.self, from: data),
              (1...PullRequestChangeSnapshot.schemaVersion).contains(value.version) else { return nil }
        // Optional fields decode absent v1 conversations and v1/v2 lifecycle state quietly.
        // Keep identity, epoch, revision, PR/reviewer history and coverage barriers intact.
        value.version = PullRequestChangeSnapshot.schemaVersion
        guard (try? Self.validate(value)) != nil else { return nil }
        return value
    }

    func save(_ snapshot: PullRequestChangeSnapshot) throws {
        try Self.validate(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        try write(data)
    }

    static func validate(_ value: PullRequestChangeSnapshot) throws {
        guard value.version == PullRequestChangeSnapshot.schemaVersion,
              value.identity.count == 64, value.sources.count <= 64,
              (value.conversationScopes?.count ?? 0) <= 64,
              value.conversationScopes?.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              (value.lifecycleScopes?.count ?? 0) <= 64,
              (value.lifecycleScopes?.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 } ?? true),
              (value.lifecycles?.count ?? 0) <= GitHubLifecyclePlan.maximumPullRequests,
              (value.lifecycles?.allSatisfy { id, pr in
                  !id.isEmpty && id.utf8.count <= 256 && !pr.repositoryID.isEmpty
                      && pr.repositoryID.utf8.count <= 256 && pr.number > 0
                      && !pr.sourceIDs.isEmpty && pr.sourceIDs.count <= 64
                      && Set(pr.sourceIDs).count == pr.sourceIDs.count
                      && pr.sourceIDs.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 }
              } ?? true),
              value.sources.values.reduce(0, { total, source in
                  total + (source.conversations?.values.reduce(0, { $0 + $1.commentIDs.count }) ?? 0)
              }) <= 100_000,
              value.sources.values.reduce(0, { $0 + ($1.authored?.count ?? 0) + ($1.requested?.count ?? 0) }) <= maximumEntries,
              value.sources.allSatisfy({ key, source in
                  !key.isEmpty && key.utf8.count <= 128
                      && (source.conversations?.count ?? 0) <= GitHubConversationPlan.maximumPullRequests
                      && (source.conversations?.allSatisfy { id, conversation in
                          !id.isEmpty && id.utf8.count <= 256 && !conversation.repositoryID.isEmpty
                              && conversation.repositoryID.utf8.count <= 256 && conversation.number > 0
                              && conversation.fingerprint.count == 64 && conversation.commentIDs.count <= 3000
                              && (conversation.reviewCommentIDs?.count ?? 0) <= 3000
                              && (conversation.reviewCommentIDs?.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 } ?? true)
                              && Set(conversation.commentIDs).count == conversation.commentIDs.count
                              && conversation.commentIDs.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
                      } ?? true)
                      && [source.authored, source.requested].allSatisfy { section in
                      section?.allSatisfy { id, pr in
                          !id.isEmpty && id.utf8.count <= 256 && !pr.repositoryID.isEmpty
                              && pr.repositoryID.utf8.count <= 256 && pr.number > 0
                              && (pr.reviewers?.count ?? 0) <= 50
                              && (pr.reviewers?.allSatisfy { key, review in
                                  key.count == 64 && !review.id.isEmpty && review.id.utf8.count <= 256
                              } ?? true)
                      } ?? true
                  }
              }) else { throw Failure.invalidSnapshot }
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try removeOrphanedWrites(in: directory)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.unavailable
        }
        defer { try? manager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else { throw Failure.unavailable }
    }

    private static func removeOrphanedWrites(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "tmp" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            try FileManager.default.removeItem(at: file)
        }
    }
}
