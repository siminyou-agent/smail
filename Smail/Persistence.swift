import Foundation
import CryptoKit

struct BatchDisk {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Smail", isDirectory: true)
    }
    func file(_ account: String) -> URL {
        let key = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key + ".json")
    }
    func load(_ account: String) throws -> Batch {
        let url = file(account)
        guard FileManager.default.fileExists(atPath: url.path) else { return Batch(account: account) }
        let batch = try JSONDecoder().decode(Batch.self, from: Data(contentsOf: url))
        guard batch.account == account else { throw SmailError.message("本地批次账号不匹配。") }
        return batch
    }
    func save(_ batch: Batch) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(batch).write(to: file(batch.account), options: [.atomic, .completeFileProtection])
    }
    func remove(_ account: String) throws {
        let url = file(account)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
