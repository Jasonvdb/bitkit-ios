#if DEBUG
    import Foundation
    import PaykitV2

    /// Demo: Paykit v0.2's `WalletStore`, kept in memory and written to one JSON file after every commit.
    ///
    /// Both the Paykit app (its own namespaces) and the in-process signer (`signer/<identity>`) keep their state here.
    ///
    /// Shortcuts, fine for a local regtest demo and never for real funds:
    /// - The file is not encrypted. It holds the app's signing keys and the signer's records, protected only by the
    ///   app sandbox and iOS file protection (`completeFileProtection`). It is excluded from iCloud backup.
    /// - One process only. Writer leases live in memory, so they end with the process, as the contract asks; there is
    ///   no lock against a second process on the same file.
    /// - Each commit rewrites the whole file (atomically), so a commit is durable when `commitIf` returns.
    final class PaykitV2FileStore: PaykitV2.WalletStore, @unchecked Sendable {
        private let fileURL: URL
        private let lock = NSLock()
        private var owners: [String: Data] = [:]
        private var rows: [String: [Data: Data]]

        init(fileURL: URL) throws {
            self.fileURL = fileURL
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try? mutableDirectory.setResourceValues(directoryValues)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                rows = try Self.decode(Data(contentsOf: fileURL))
            } else {
                rows = [:]
            }
        }

        var rowCount: Int {
            lock.withLock { rows.values.reduce(0) { $0 + $1.count } }
        }

        func get(namespace: String, key: Data) throws -> Data? {
            lock.withLock { rows[namespace]?[key] }
        }

        func scan(namespace: String, prefix: Data, after: Data?, limit: UInt32) throws -> [PaykitV2.StoreEntry] {
            lock.withLock {
                (rows[namespace] ?? [:])
                    .filter { key, _ in key.starts(with: prefix) && (after.map { $0.lexicographicallyPrecedes(key) } ?? true) }
                    .sorted { $0.key.lexicographicallyPrecedes($1.key) }
                    .prefix(Int(limit))
                    .map { PaykitV2.StoreEntry(key: $0.key, value: $0.value) }
            }
        }

        func acquire(namespace: String, owner: Data) throws -> Bool {
            lock.withLock {
                guard owners[namespace] == nil else { return false }
                owners[namespace] = owner
                return true
            }
        }

        func release(namespace: String, owner: Data) throws {
            lock.withLock {
                if owners[namespace] == owner { owners[namespace] = nil }
            }
        }

        /// Applies the writes to a copy, writes the copy to disk, and only then makes it the live state. If the file
        /// write fails nothing was applied, so the answer is `Unavailable` (the SDK may retry).
        func commitIf(namespace: String, owner: Data, writes: [PaykitV2.StoreWrite]) throws -> Bool {
            try lock.withLock {
                guard owners[namespace] == owner else { return false }
                var updated = rows[namespace] ?? [:]
                for write in writes {
                    switch write {
                    case let .put(key, value): updated[key] = value
                    case let .delete(key): updated[key] = nil
                    case let .deletePrefix(prefix): updated = updated.filter { !$0.key.starts(with: prefix) }
                    }
                }
                var next = rows
                next[namespace] = updated.isEmpty ? nil : updated
                do {
                    try Self.encode(next).write(to: fileURL, options: [.atomic, .completeFileProtection])
                } catch {
                    throw PaykitV2.StorageError.Unavailable
                }
                rows = next
                return true
            }
        }

        // MARK: - File format: {"<namespace>": {"<base64 key>": "<base64 value>"}}

        private static func encode(_ rows: [String: [Data: Data]]) throws -> Data {
            var file: [String: [String: String]] = [:]
            for (namespace, entries) in rows {
                var encoded: [String: String] = [:]
                for (key, value) in entries {
                    encoded[key.base64EncodedString()] = value.base64EncodedString()
                }
                file[namespace] = encoded
            }
            return try JSONEncoder().encode(file)
        }

        private static func decode(_ data: Data) throws -> [String: [Data: Data]] {
            let file = try JSONDecoder().decode([String: [String: String]].self, from: data)
            var rows: [String: [Data: Data]] = [:]
            for (namespace, entries) in file {
                var decoded: [Data: Data] = [:]
                for (key, value) in entries {
                    guard let keyData = Data(base64Encoded: key), let valueData = Data(base64Encoded: value) else {
                        throw PaykitV2.StorageError.Unavailable
                    }
                    decoded[keyData] = valueData
                }
                rows[namespace] = decoded
            }
            return rows
        }
    }
#endif
