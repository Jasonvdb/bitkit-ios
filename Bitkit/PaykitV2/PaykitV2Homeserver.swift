#if DEBUG
    import Foundation
    import PaykitV2

    /// Demo: Paykit v0.2's `WalletHomeserver`, with two backends chosen by `PAYKIT_V2_HOMESERVER`.
    ///
    /// - `fake`: the local fake Homeserver of the demo (`http://127.0.0.1:18590`): `GET|PUT|DELETE /{z32}{path}`,
    ///   no auth, `/pub` and `/priv` both stored, in memory. Default, and what automated tests use.
    /// - `staging`: Pubky staging. Requests go to `<staging URL><path>` with `pubky-host: <z32>`. For Bitkit's own
    ///   identity they carry the root session cookie (`<z32>=<secret>`), which the signer needs to write
    ///   `/pub/pubky-dispatch/v1/` and to read and write `/priv/pubky-dispatch/v1/signer-backup.json`. The session
    ///   comes from `signIn` (bitkit-core `pubkySignIn`), is kept in memory only, and is renewed once on a 401.
    ///
    /// Every call is bounded at 10 seconds, the limit Paykit applies to the Homeserver. 404 reads as an absent file.
    final class PaykitV2Homeserver: PaykitV2.WalletHomeserver, @unchecked Sendable {
        enum Backend {
            case fake(baseUrl: URL)
            case staging(baseUrl: URL, signIn: @Sendable () async throws -> String)
        }

        private let backend: Backend
        private let urlSession: URLSession
        private let lock = NSLock()
        /// The root session secret, `<z32>:<cookie>` as pubky's `export_secret` gives it. Never logged.
        private var sessionSecret: String?

        init(backend: Backend) {
            self.backend = backend
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            urlSession = URLSession(configuration: configuration)
        }

        var backendName: String {
            switch backend {
            case .fake: "fake"
            case .staging: "staging"
            }
        }

        func get(identity: Data, path: String) async throws -> Data? {
            let (status, body) = try await send("GET", identity: identity, path: path, body: nil)
            switch status {
            case 200 ..< 300: return body
            case 404, 410: return nil
            default: throw Self.error(forStatus: status)
            }
        }

        func put(identity: Data, path: String, bytes: Data) async throws {
            let (status, _) = try await send("PUT", identity: identity, path: path, body: bytes)
            guard (200 ..< 300).contains(status) else { throw Self.error(forStatus: status) }
        }

        func delete(identity: Data, path: String) async throws {
            let (status, _) = try await send("DELETE", identity: identity, path: path, body: nil)
            // Deleting a file that is already gone has the effect asked for.
            guard (200 ..< 300).contains(status) || status == 404 else { throw Self.error(forStatus: status) }
        }

        // MARK: - Requests

        private func send(_ method: String, identity: Data, path: String, body: Data?) async throws -> (Int, Data) {
            let z32 = PubkyZ32.encode(identity)
            switch backend {
            case let .fake(baseUrl):
                let request = makeRequest(method, url: Self.url(baseUrl, z32: z32, path: path), body: body)
                return try await perform(request)

            case let .staging(baseUrl, signIn):
                var request = makeRequest(method, url: Self.url(baseUrl, z32: nil, path: path), body: body)
                request.setValue(z32, forHTTPHeaderField: "pubky-host")
                guard let secret = try await ownSession(for: z32, signIn: signIn, renew: false) else {
                    // Another identity: public reads need no session.
                    return try await perform(request)
                }
                request.setValue(Self.cookie(secret), forHTTPHeaderField: "Cookie")
                let first = try await perform(request)
                guard first.0 == 401, let renewed = try await ownSession(for: z32, signIn: signIn, renew: true) else {
                    return first
                }
                request.setValue(Self.cookie(renewed), forHTTPHeaderField: "Cookie")
                return try await perform(request)
            }
        }

        /// The root session for `z32` when it is the signed-in identity, else nil.
        private func ownSession(
            for z32: String,
            signIn: @Sendable () async throws -> String,
            renew: Bool
        ) async throws -> String? {
            if !renew, let cached = lock.withLock({ sessionSecret }) {
                return Self.sessionIdentity(cached) == z32 ? cached : nil
            }
            let fresh: String
            do {
                fresh = try await signIn()
            } catch {
                Logger.warn("PAYKIT_V2 staging sign-in failed: \(type(of: error))", context: "PaykitV2")
                throw PaykitV2.HomeserverError.Refused
            }
            lock.withLock { sessionSecret = fresh }
            return Self.sessionIdentity(fresh) == z32 ? fresh : nil
        }

        private func makeRequest(_ method: String, url: URL, body: Data?) -> URLRequest {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.httpMethod = method
            request.httpShouldHandleCookies = false
            if let body {
                request.httpBody = body
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            }
            return request
        }

        private func perform(_ request: URLRequest) async throws -> (Int, Data) {
            do {
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw PaykitV2.HomeserverError.Unavailable }
                return (http.statusCode, data)
            } catch let error as URLError where error.code == .timedOut {
                throw PaykitV2.HomeserverError.Timeout
            } catch let error as PaykitV2.HomeserverError {
                throw error
            } catch {
                throw PaykitV2.HomeserverError.Unavailable
            }
        }

        // MARK: - Helpers

        private static func url(_ base: URL, z32: String?, path: String) -> URL {
            let trimmedBase = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
            let normalizedPath = path.hasPrefix("/") ? path : "/" + path
            let prefix = z32.map { "/\($0)" } ?? ""
            return URL(string: trimmedBase + prefix + normalizedPath)!
        }

        private static func sessionIdentity(_ secret: String) -> String? {
            secret.split(separator: ":", maxSplits: 1).first.map(String.init)
        }

        /// pubky 0.6 names the session cookie after the user's z32 key.
        private static func cookie(_ secret: String) -> String {
            let parts = secret.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return "" }
            return "\(parts[0])=\(parts[1])"
        }

        private static func error(forStatus status: Int) -> PaykitV2.HomeserverError {
            switch status {
            case 401, 403: .Refused
            case 408, 504: .Timeout
            default: .Unavailable
            }
        }
    }
#endif
