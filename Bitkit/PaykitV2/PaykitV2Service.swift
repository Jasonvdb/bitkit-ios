#if DEBUG
    import Foundation
    import PaykitV2

    /// Demo: Bitkit's Paykit v0.2 host. It enrols Bitkit's Pubky identity at the local Pubky Dispatch on first start
    /// (approved by the in-process signer), loads the app on later starts, and runs the feed loop.
    ///
    /// Runs only in Debug local-regtest builds (`PaykitV2Launcher`). Every log line carries the marker `PAYKIT_V2`
    /// and no secret: identities and app IDs are public, keys are never printed.
    ///
    /// Demo shortcuts (never for real funds):
    /// - The identity secret is handed to the in-process signer (`demoApproveOwnApp`), which approves this app
    ///   without asking the user.
    /// - `host.json` keeps the enrolment reference, the client key and the auth secret unencrypted in the app
    ///   sandbox, next to the store file (see `PaykitV2FileStore`).
    actor PaykitV2Service {
        static let shared = PaykitV2Service()
        static let marker = "PAYKIT_V2"
        static let clientId = "bitkit.demo"

        struct Launch: Sendable {
            /// The 32-byte Ed25519 secret of Bitkit's Pubky identity.
            let identitySecret: Data
            /// The z-base-32 public identity of that secret.
            let identityZ32: String
            /// The folder for this identity's store and host state.
            let directory: URL
            let config: PaykitV2Config
            /// Signs in to the staging Homeserver with the identity's root key; only used by the staging backend.
            let stagingSignIn: @Sendable () async throws -> String
        }

        /// The host's enrolment state, written before and after each enrolment step.
        private struct HostState: Codable {
            var reference: Data
            var clientKey: Data
            var authSecret: Data
            var appId: Data?
        }

        private(set) var wallet: PaykitV2.NativeWallet?
        private(set) var identity: Data?
        private var loopTask: Task<Void, Never>?
        private var seenRequests: Set<String> = []

        /// Starts once per process; later calls do nothing.
        func start(_ launch: Launch) {
            guard loopTask == nil else { return }
            loopTask = Task { await self.run(launch) }
        }

        private func run(_ launch: Launch) async {
            let config = launch.config
            Self.log(
                "starting identity=\(launch.identityZ32) homeserver=\(config.homeserverBackend.rawValue) "
                    + "dispatchOrigin=\(config.dispatchOrigin) dispatchListener=\(config.dispatchListener)"
            )

            let wallet: PaykitV2.NativeWallet
            let store: PaykitV2FileStore
            let homeserver: PaykitV2Homeserver
            do {
                store = try PaykitV2FileStore(fileURL: launch.directory.appendingPathComponent("store.json"))
                homeserver = PaykitV2Homeserver(backend: Self.homeserverBackend(launch))
                wallet = try await openWallet(launch, store: store, homeserver: homeserver)
            } catch {
                Self.log("start failed: \(Self.describe(error))", level: .error)
                loopTask = nil
                return
            }

            self.wallet = wallet
            identity = try? await wallet.identity()
            await allowPeers(launch.config.allowPeers, wallet: wallet)
            await feedLoop(launch, wallet: wallet, store: store, homeserver: homeserver)
        }

        // MARK: - Enrolment or load

        private func openWallet(
            _ launch: Launch,
            store: PaykitV2FileStore,
            homeserver: PaykitV2Homeserver
        ) async throws -> PaykitV2.NativeWallet {
            let config = launch.config
            let host = try PaykitV2.WalletHost.newLocalDevelopment(
                store: store,
                homeserver: homeserver,
                method: PaykitV2OnchainMethod(),
                declaration: PaykitV2OnchainMethod.declaration,
                endpoints: PaykitV2OnchainMethod.endpoints,
                dispatchOrigin: config.dispatchOrigin,
                dispatchListener: config.dispatchListener,
                config: nil
            )

            let stateURL = launch.directory.appendingPathComponent("host.json")
            if let state = try Self.readState(stateURL), let appId = state.appId {
                // Later start: give the signer its due work (renewals), then open the app. No enrolment.
                do {
                    let due = try await PaykitV2.demoSignerRunDue(
                        identitySecret: launch.identitySecret,
                        dispatchOrigin: config.dispatchOrigin,
                        dispatchListener: config.dispatchListener,
                        homeserver: homeserver,
                        store: store
                    )
                    Self.log("signer run due ok moreDue=\(due.moreDue)")
                } catch {
                    Self.log("signer run due failed: \(Self.describe(error))", level: .warn)
                }
                let wallet = try await host.load(appId: appId)
                Self.log("loaded app=\(appId.hex) without enrolment storeRows=\(store.rowCount)")
                return wallet
            }

            return try await enroll(launch, host: host, store: store, homeserver: homeserver, stateURL: stateURL)
        }

        private func enroll(
            _ launch: Launch,
            host: PaykitV2.WalletHost,
            store: PaykitV2FileStore,
            homeserver: PaykitV2Homeserver,
            stateURL: URL
        ) async throws -> PaykitV2.NativeWallet {
            let config = launch.config
            var state = try Self.readState(stateURL)
                ?? HostState(reference: Self.randomBytes(16), clientKey: Self.randomBytes(32), authSecret: Self.randomBytes(32))
            try Self.writeState(state, to: stateURL)
            Self.log("enrolment started identity=\(launch.identityZ32)")

            let enrollment = PaykitV2.WalletEnrollment(store: store)
            let info = try await enrollment.beginEnrollment(reference: state.reference)
            let capabilities = info.appRecordPath + ":rw"
            let request = try await enrollment.prepareEnrollment(
                reference: state.reference,
                clientId: Self.clientId,
                clientKey: state.clientKey,
                capabilities: capabilities,
                authSecret: state.authSecret,
                scopes: PaykitV2.WalletScopes(pay: true, request: true, contacts: true)
            )
            Self.log("enrolment request app=\(info.appId.hex) record=\(info.appRecordPath) requestHash=\(request.requestHash.hex)")

            // The in-process signer approves the request at the Dispatch and returns the claim. The claim must be
            // accepted at once: the signer refuses the same request again until the app has joined.
            let approval = try await PaykitV2.demoApproveOwnApp(
                identitySecret: launch.identitySecret,
                dispatchOrigin: config.dispatchOrigin,
                dispatchListener: config.dispatchListener,
                homeserver: homeserver,
                store: store,
                signedRequest: request.signedRequest,
                clientId: Self.clientId,
                clientKey: state.clientKey,
                capabilities: capabilities,
                authSecret: state.authSecret
            )
            Self.log("signer approved identity=\(PubkyZ32.encode(approval.identity)) claimBytes=\(approval.claim.count)")

            try await enrollment.acceptApproval(reference: state.reference, identity: approval.identity, claim: approval.claim)
            let wallet = try await host.completeEnrollment(reference: state.reference)
            let appId = try await wallet.appId()
            state.appId = appId
            try Self.writeState(state, to: stateURL)
            Self.log("enrolled app=\(appId.hex) identity=\(PubkyZ32.encode(approval.identity)) storeRows=\(store.rowCount)")
            return wallet
        }

        // MARK: - Admission

        /// Demo: admits the Pubky IDs in `PAYKIT_V2_ALLOW_PEERS`, so a scripted peer's requests reach Bitkit before the
        /// contacts step wires admission to Bitkit's contact list.
        private func allowPeers(_ peers: [String], wallet: PaykitV2.NativeWallet) async {
            for peer in peers {
                guard let bytes = PubkyZ32.decodeIdentity(peer) else {
                    Self.log("allowConnect skipped, not a Pubky ID: \(peer)", level: .warn)
                    continue
                }
                do {
                    try await wallet.allowConnect(payee: bytes)
                    Self.log("allowConnect \(PubkyZ32.encode(bytes)) ok")
                } catch {
                    Self.log("allowConnect \(PubkyZ32.encode(bytes)) failed: \(Self.describe(error))", level: .warn)
                }
            }
        }

        // MARK: - Feed loop

        private func feedLoop(
            _ launch: Launch,
            wallet: PaykitV2.NativeWallet,
            store: PaykitV2FileStore,
            homeserver: PaykitV2Homeserver
        ) async {
            Self.log("feed loop running")
            var round: UInt64 = 0
            while !Task.isCancelled {
                round += 1
                do {
                    try await drain(launch, wallet: wallet, store: store, homeserver: homeserver)
                    try await logNewRequests(wallet: wallet)
                    let wake = try await wallet.feedWait(seconds: 20)
                    Self.log("feed wait round=\(round) wake=\(wake)")
                } catch {
                    Self.log("feed loop error round=\(round): \(Self.describe(error))", level: .warn)
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }

        /// Receives until no more work is reported. When the app waits for scope keys, the signer runs its due work.
        private func drain(
            _ launch: Launch,
            wallet: PaykitV2.NativeWallet,
            store: PaykitV2FileStore,
            homeserver: PaykitV2Homeserver
        ) async throws {
            var passes = 0
            while passes < 50 {
                passes += 1
                let report = try await wallet.receive()
                for event in report.events {
                    Self.log("event \(Self.describe(event.data))")
                }
                if !report.events.isEmpty || report.more || report.scopeKeysAwaited || report.recordsUnlisted != nil {
                    Self.log(
                        "receive ok events=\(report.events.count) more=\(report.more) stopped=\(report.stopped) "
                            + "scopeKeysAwaited=\(report.scopeKeysAwaited) recordsUnlisted=\(report.recordsUnlisted ?? "none")"
                    )
                }
                if report.scopeKeysAwaited {
                    let due = try await PaykitV2.demoSignerRunDue(
                        identitySecret: launch.identitySecret,
                        dispatchOrigin: launch.config.dispatchOrigin,
                        dispatchListener: launch.config.dispatchListener,
                        homeserver: homeserver,
                        store: store
                    )
                    Self.log("signer run due for scope keys moreDue=\(due.moreDue)")
                }
                if let last = report.events.last(where: { $0.id != nil })?.id {
                    try await wallet.acknowledgeEvents(through: last)
                }
                guard report.more || report.scopeKeysAwaited else { return }
            }
            Self.log("receive still reports more after \(passes) passes; continuing after the feed wait", level: .warn)
        }

        private func logNewRequests(wallet: PaykitV2.NativeWallet) async throws {
            for request in try await wallet.requests() {
                let key = request.id.requestHash.hex + ":\(request.status)"
                guard seenRequests.insert(key).inserted else { continue }
                Self.log(
                    "request from=\(PubkyZ32.encode(request.id.payee)) ref=\(request.paymentReference) "
                        + "amount=\(request.amount.value) \(request.amount.asset) status=\(request.status) "
                        + "requestHash=\(request.id.requestHash.hex) manualOnly=\(request.manualOnly)"
                )
            }
        }

        // MARK: - Helpers

        private static func homeserverBackend(_ launch: Launch) -> PaykitV2Homeserver.Backend {
            switch launch.config.homeserverBackend {
            case .fake: .fake(baseUrl: launch.config.fakeHomeserverUrl)
            case .staging: .staging(baseUrl: launch.config.stagingHomeserverUrl, signIn: launch.stagingSignIn)
            }
        }

        private static func readState(_ url: URL) throws -> HostState? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(HostState.self, from: Data(contentsOf: url))
        }

        private static func writeState(_ state: HostState, to url: URL) throws {
            try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtection])
        }

        private static func randomBytes(_ count: Int) -> Data {
            var generator = SystemRandomNumberGenerator()
            return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        }

        /// The event's case name and, for a received or dropped message, its public fields.
        private static func describe(_ data: PaykitV2.WalletEventData) -> String {
            switch data {
            case let .messageReceived(_, seq, kind, msgId, sender):
                return "messageReceived kind=\(kind) msgId=\(msgId) seq=\(seq) sender=\(PubkyZ32.encode(sender))"
            default:
                let mirror = Mirror(reflecting: data)
                return mirror.children.first?.label ?? String(describing: data)
            }
        }

        /// Error text for the log: the case and its fields as the bindings print them, which carry no secrets.
        private static func describe(_ error: Error) -> String {
            "\(type(of: error)).\(error)"
        }

        enum Level { case info, warn, error }

        static func log(_ message: String, level: Level = .info) {
            let line = "\(marker) \(message)"
            switch level {
            case .info: Logger.info(line, context: "PaykitV2")
            case .warn: Logger.warn(line, context: "PaykitV2")
            case .error: Logger.error(line, context: "PaykitV2")
            }
        }
    }
#endif
