#if DEBUG
    import Foundation
    import PaykitV2

    /// Demo: a launch check that Paykit v0.2 (module `PaykitV2`) loads and runs beside Paykit v0.1.
    ///
    /// It starts an enrollment in a throwaway in-memory store, signs an app request, and reads both back
    /// through a second handle on the same store. Nothing touches the network or the keychain, and the
    /// store is dropped when the probe returns.
    ///
    /// This file imports only `PaykitV2`, because v0.1 and v0.2 share type names such as `Amount`.
    enum PaykitV2Probe {
        struct Report {
            let appId: String
            let appRecordPath: String
            let requestHash: String
            let signedRequestBytes: Int
            let readBackMatches: Bool
            let storedRows: Int
        }

        static func run() async throws -> Report {
            let store = MemoryStore()
            let reference = try randomBytes(16)
            let clientKey = try randomBytes(32)
            let authSecret = try randomBytes(32)
            let scopes = PaykitV2.WalletScopes(pay: true, request: true)

            let enrollment = PaykitV2.WalletEnrollment(store: store)
            let info = try await enrollment.beginEnrollment(reference: reference)
            let request = try await enrollment.prepareEnrollment(
                reference: reference,
                clientId: "bitkit.probe",
                clientKey: clientKey,
                capabilities: info.appRecordPath + ":rw",
                authSecret: authSecret,
                scopes: scopes
            )

            // A second handle on the same store must find the same installation and the same signed request.
            let reopened = PaykitV2.WalletEnrollment(store: store)
            let infoAgain = try await reopened.beginEnrollment(reference: reference)
            let requestAgain = try await reopened.prepareEnrollment(
                reference: reference,
                clientId: "bitkit.probe",
                clientKey: clientKey,
                capabilities: info.appRecordPath + ":rw",
                authSecret: authSecret,
                scopes: scopes
            )

            return Report(
                appId: info.appId.hex,
                appRecordPath: info.appRecordPath,
                requestHash: request.requestHash.hex,
                signedRequestBytes: request.signedRequest.count,
                readBackMatches: infoAgain == info && requestAgain.requestHash == request.requestHash,
                storedRows: store.rowCount
            )
        }

        private static func randomBytes(_ count: Int) throws -> Data {
            var bytes = [UInt8](repeating: 0, count: count)
            let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            guard status == errSecSuccess else { throw ProbeError.randomUnavailable(status) }
            return Data(bytes)
        }

        enum ProbeError: Error {
            case randomUnavailable(OSStatus)
        }
    }

    /// An in-memory `WalletStore` for the probe only: one process, no durability, no encryption.
    private final class MemoryStore: PaykitV2.WalletStore, @unchecked Sendable {
        private let lock = NSLock()
        private var owners: [String: Data] = [:]
        private var rows: [String: [Data: Data]] = [:]

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

        func commitIf(namespace: String, owner: Data, writes: [PaykitV2.StoreWrite]) throws -> Bool {
            lock.withLock {
                guard owners[namespace] == owner else { return false }
                for write in writes {
                    switch write {
                    case let .put(key, value): rows[namespace, default: [:]][key] = value
                    case let .delete(key): rows[namespace]?[key] = nil
                    case let .deletePrefix(prefix):
                        rows[namespace] = rows[namespace]?.filter { !$0.key.starts(with: prefix) }
                    }
                }
                return true
            }
        }
    }
#endif
