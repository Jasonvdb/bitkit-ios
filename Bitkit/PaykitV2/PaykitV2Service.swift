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

        /// What Bitkit knows about one saved contact's admission, kept in `contacts.json` so a relaunch shows the same
        /// state without asking again.
        private struct ContactLink: Codable {
            /// The `resend_request` sent as an admission probe (see `tendContacts`), while its delivery is open.
            var probeMsgId: String?
            /// When the contact was first known to have allowed Bitkit too.
            var connectedAtMs: UInt64?
        }

        /// A one-time request Bitkit sent, as the host remembers it (`outgoing.json`).
        private struct OutgoingEntry: Codable {
            var reference: String
            var note: String?
            /// The payer, z-base-32.
            var payer: String
            var sats: UInt64
            var address: String
            var createdAtMs: UInt64
            var expiresAtMs: UInt64?
            /// The request message, while its delivery is not known to be accepted.
            var msgId: String
            var delivered: Bool
            /// The transaction that paid it, once its proof verified.
            var txid: String?
            /// The receipt Bitkit sent.
            var receiptMsgId: String?
        }

        private(set) var wallet: PaykitV2.NativeWallet?
        private(set) var identity: Data?
        private var loopTask: Task<Void, Never>?
        private var seenRequests: Set<String> = []

        /// Bitkit's saved contacts (v0.1 contact records), as 32-byte identities in the order they came.
        private var savedContacts: [Data] = []
        /// The contacts `allowConnect` succeeded for in this process. Each start admits every saved contact again; the
        /// call is idempotent.
        private var allowedThisRun: Set<Data> = []
        private var links: [String: ContactLink] = [:]
        private var linksURL: URL?
        private var lastLoggedDelivery: [String: String] = [:]
        private var isTending = false
        private var tendAgain = false

        /// The on-chain method, kept to read which transaction verified a request's address.
        private var method: PaykitV2OnchainMethod?
        /// One-time requests Bitkit sent, by request hash (hex), kept in `outgoing.json`. Paykit's payee activity has
        /// no payment reference, address or note, so the host keeps them.
        private var outgoing: [String: OutgoingEntry] = [:]
        private var outgoingURL: URL?
        /// The latest payee activity status per request hash, as read from `payeeActivity()`.
        private var payeeStatus: [String: PaykitV2.PayeeStatus] = [:]
        /// Proofs Bitkit could not credit yet (the transaction was not visible, or not enough), by record (hex): tries.
        private var unconfirmedProofs: [String: Int] = [:]
        private var isTendingPayee = false

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
            linksURL = launch.directory.appendingPathComponent("contacts.json")
            links = Self.readLinks(linksURL)
            outgoingURL = launch.directory.appendingPathComponent("outgoing.json")
            outgoing = Self.readOutgoing(outgoingURL)
            publishState()
            publishOutgoing()
            await tendContacts()
            await feedLoop(launch, wallet: wallet, store: store, homeserver: homeserver)
        }

        // MARK: - Enrolment or load

        private func openWallet(
            _ launch: Launch,
            store: PaykitV2FileStore,
            homeserver: PaykitV2Homeserver
        ) async throws -> PaykitV2.NativeWallet {
            let config = launch.config
            let method = PaykitV2OnchainMethod(esploraUrl: config.esploraUrl)
            self.method = method
            let host = try PaykitV2.WalletHost.newLocalDevelopment(
                store: store,
                homeserver: homeserver,
                method: method,
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

        // MARK: - Contacts and admission

        /// Takes Bitkit's saved contacts. Each one is admitted with `allowConnect` once per process, so contacts saved
        /// before enrolment, or while the app was closed, are admitted at the next start.
        func setSavedContacts(_ publicKeys: [String]) async {
            var seen: Set<Data> = []
            savedContacts = publicKeys.compactMap { PubkyZ32.decodeIdentity($0) }.filter { seen.insert($0).inserted }
            publishState()
            await tendContacts()
        }

        /// A contact the user just saved in Bitkit's Add Contact flow.
        func addContact(_ publicKey: String) async {
            guard let identity = PubkyZ32.decodeIdentity(publicKey) else {
                Self.log("contact skipped, not a Pubky ID", level: .warn)
                return
            }
            Self.log("contact added \(PubkyZ32.encode(identity))")
            if !savedContacts.contains(identity) {
                savedContacts.append(identity)
            }
            publishState()
            await tendContacts()
        }

        /// Admits every saved contact and works out whether each one has admitted Bitkit too. One pass at a time; a call
        /// during a pass runs one more pass after it.
        private func tendContacts() async {
            guard let wallet else { return }
            if isTending {
                tendAgain = true
                return
            }
            isTending = true
            defer { isTending = false }
            repeat {
                tendAgain = false
                await tendContactsOnce(wallet)
            } while tendAgain
        }

        /// Admission is per direction: `allowConnect` lets the contact write to Bitkit's inbox, and only the contact can
        /// let Bitkit write to theirs. Paykit v0.2 has no call that reads the other side's decision, so Bitkit learns it
        /// from a delivery: it sends the contact a `resend_request` that selects one random, unknown message ID. The
        /// contact's Dispatch refuses it (`WaitingForAdmission`) until the contact allows Bitkit, the outbox tries it
        /// again at each flush, and its acceptance shows the contact allowed Bitkit. The contact has nothing to re-send,
        /// so the request changes nothing on their side. Demo shortcut: a real wallet would track admission with a
        /// purpose-made message or a Dispatch read.
        private func tendContactsOnce(_ wallet: PaykitV2.NativeWallet) async {
            for contact in savedContacts where !allowedThisRun.contains(contact) {
                do {
                    try await wallet.allowConnect(payee: contact)
                    allowedThisRun.insert(contact)
                    Self.log("allowConnect \(PubkyZ32.encode(contact)) ok")
                } catch {
                    Self.log("allowConnect \(PubkyZ32.encode(contact)) failed: \(Self.describe(error))", level: .warn)
                }
            }

            let open = savedContacts.filter { allowedThisRun.contains($0) && links[PubkyZ32.encode($0)]?.connectedAtMs == nil }
            if open.contains(where: { links[PubkyZ32.encode($0)]?.probeMsgId != nil }) {
                do {
                    try await wallet.flush()
                } catch {
                    Self.log("outbox flush failed: \(Self.describe(error))", level: .warn)
                }
            }

            for contact in open {
                let key = PubkyZ32.encode(contact)
                var link = links[key] ?? ContactLink()
                if let msgId = link.probeMsgId {
                    link = await checkProbe(msgId, contact: key, link: link, wallet: wallet)
                }
                if link.connectedAtMs == nil, link.probeMsgId == nil {
                    do {
                        let probe = PaykitV2.ResendSelection(msgIds: [UUID().uuidString.lowercased()])
                        let msgId = try await wallet.requestResend(counterparty: contact, selection: probe)
                        link.probeMsgId = msgId
                        Self.log("admission probe sent to \(key) msg=\(msgId)")
                        link = await checkProbe(msgId, contact: key, link: link, wallet: wallet)
                    } catch {
                        Self.log("admission probe to \(key) failed: \(Self.describe(error))", level: .warn)
                    }
                }
                links[key] = link
            }
            saveLinks()
            publishState()
        }

        private func checkProbe(
            _ msgId: String,
            contact: String,
            link: ContactLink,
            wallet: PaykitV2.NativeWallet
        ) async -> ContactLink {
            var link = link
            let delivery: PaykitV2.MessageDelivery?
            do {
                delivery = try await wallet.messageDelivery(msgId: msgId)
            } catch {
                Self.log("admission probe to \(contact) unreadable: \(Self.describe(error))", level: .warn)
                return link
            }
            // Logged when the kind of state changes, not at every try.
            let state: String
            switch delivery {
            case let .accepted(acceptedAtMs):
                link.connectedAtMs = acceptedAtMs
                link.probeMsgId = nil
                state = "accepted"
                Self.log("contact connected \(contact) via=probe acceptedAtMs=\(acceptedAtMs)")
            case .waitingForAdmission:
                state = "waitingForAdmission"
            case let .queued(_, lastError):
                state = "queued lastError=\(lastError ?? "none")"
            case .kept:
                state = "kept"
            case .certificateNotCurrent:
                state = "certificateNotCurrent"
            case let .failed(reason, _):
                // A refused probe is replaced by a new one at the next pass.
                link.probeMsgId = nil
                state = "failed reason=\(reason)"
            case .other, nil:
                link.probeMsgId = nil
                state = delivery == nil ? "unknown to the outbox" : "other"
            }
            if lastLoggedDelivery[msgId] != state {
                lastLoggedDelivery[msgId] = state
                Self.log("admission probe to \(contact) msg=\(msgId) delivery=\(state)")
            }
            return link
        }

        /// A message from a contact Bitkit allowed also shows the contact allowed Bitkit: the contact's own Dispatch grants
        /// a reply to whoever its apps write to.
        private func noteMessage(from sender: Data) {
            let key = PubkyZ32.encode(sender)
            guard allowedThisRun.contains(sender), links[key]?.connectedAtMs == nil else { return }
            var link = links[key] ?? ContactLink()
            link.connectedAtMs = UInt64(Date().timeIntervalSince1970 * 1000)
            links[key] = link
            Self.log("contact connected \(key) via=message")
            saveLinks()
            publishState()
        }

        private var hasOpenProbes: Bool {
            savedContacts.contains { links[PubkyZ32.encode($0)]?.connectedAtMs == nil }
        }

        private func publishState() {
            var connections: [String: PaykitV2ContactConnection] = [:]
            for contact in savedContacts {
                let key = PubkyZ32.encode(contact)
                if links[key]?.connectedAtMs != nil {
                    connections[key] = .connected
                } else if wallet != nil {
                    connections[key] = .waiting
                }
            }
            let isReady = wallet != nil
            Task { @MainActor in
                PaykitV2DemoState.shared.apply(isReady: isReady, connections: connections)
            }
        }

        private static func readLinks(_ url: URL?) -> [String: ContactLink] {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return [:] }
            do {
                return try JSONDecoder().decode([String: ContactLink].self, from: Data(contentsOf: url))
            } catch {
                log("contacts.json unreadable, starting empty: \(error)", level: .warn)
                return [:]
            }
        }

        private func saveLinks() {
            guard let linksURL else { return }
            do {
                try JSONEncoder().encode(links).write(to: linksURL, options: [.atomic, .completeFileProtection])
            } catch {
                Self.log("contacts.json not written: \(error)", level: .warn)
            }
        }

        // MARK: - Requests Bitkit sends (Bitkit is the payee)

        enum RequestError: LocalizedError {
            case notReady
            case notAPubkyId
            case unsupportedAddress
            case notRecorded

            var errorDescription: String? {
                switch self {
                case .notReady: "Payments with this contact are still starting. Try again in a moment."
                case .notAPubkyId: "This contact cannot receive payment requests."
                case .unsupportedAddress: "Bitkit could not create a receiving address for this request."
                case .notRecorded: "The payment request could not be sent. Try again."
                }
            }
        }

        /// Sends `publicKey` a one-time request for `sats`, to be paid on-chain to a new address of Bitkit's wallet.
        ///
        /// The address comes from Bitkit's LDK on-chain wallet, so the payment shows in Bitkit's balance and activity as
        /// a normal receive. The note becomes the payment reference the payer sees (Paykit v0.2 requests carry no memo).
        func sendRequest(to publicKey: String, sats: UInt64, note: String, expiresAt: Date?) async throws -> PaykitV2OutgoingRequest {
            guard let wallet else { throw RequestError.notReady }
            guard let payer = PubkyZ32.decodeIdentity(publicKey) else { throw RequestError.notAPubkyId }

            let address = try await LightningService.shared.newAddress()
            guard let identifier = PaykitV2OnchainMethod.identifier(forAddress: address) else {
                Self.log("request not sent: address type of \(address) is not supported", level: .warn)
                throw RequestError.unsupportedAddress
            }

            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let reference = uniqueReference(trimmedNote.isEmpty ? Self.generatedReference() : trimmedNote)
            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
            let expiresAtMs = expiresAt.map { UInt64($0.timeIntervalSince1970 * 1000) }
            let draft = PaykitV2.RequestDraft(
                amount: PaykitV2.Amount(asset: "btc", value: PaykitV2Sats.toBtc(sats)),
                destination: .endpoints(endpoints: [
                    PaykitV2.ListEndpoint(identifier: identifier, payload: PaykitV2OnchainMethod.payload(forAddress: address)),
                ]),
                paymentReference: reference,
                proposalExpiresAtMs: expiresAtMs,
                paymentDeadlineMs: nil,
                acceptedEndpointIdentifiers: nil,
                conversion: nil,
                recurrence: nil,
                periodDeadlineS: nil,
                perPeriodEndpoints: false,
                metadataJson: nil,
                inviteCode: nil
            )

            let sent: PaykitV2.SentRequest
            do {
                sent = try await wallet.sendRequest(to: payer, draft: draft)
            } catch {
                Self.log("request to \(PubkyZ32.encode(payer)) failed: \(Self.describe(error))", level: .error)
                throw error
            }
            guard let requestHash = sent.request?.requestHash else {
                Self.log("request to \(PubkyZ32.encode(payer)) not recorded msg=\(sent.msgId)", level: .error)
                throw RequestError.notRecorded
            }

            let key = requestHash.hex
            let delivered: Bool = if case .accepted = sent.delivery { true } else { false }
            outgoing[key] = OutgoingEntry(
                reference: reference,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                payer: PubkyZ32.encode(payer),
                sats: sats,
                address: address,
                createdAtMs: nowMs,
                expiresAtMs: expiresAtMs,
                msgId: sent.msgId,
                delivered: delivered,
                txid: nil,
                receiptMsgId: nil
            )
            payeeStatus[key] = .requested
            saveOutgoing()
            Self.log(
                "request sent to=\(PubkyZ32.encode(payer)) ref=\(reference) sats=\(sats) endpoint=\(identifier) "
                    + "address=\(address) requestHash=\(key) msg=\(sent.msgId) delivery=\(Self.describe(sent.delivery))"
            )
            publishOutgoing()
            guard let row = outgoingRow(key) else { throw RequestError.notRecorded }
            return row
        }

        /// Reads the payee activity, credits every proof that verifies on-chain (verify, then confirm, which records and
        /// sends the receipt), checks undelivered requests, and publishes the rows.
        private func tendPayeeActivity() async {
            guard let wallet, !isTendingPayee else { return }
            isTendingPayee = true
            defer { isTendingPayee = false }

            await checkDeliveries(wallet)
            do {
                var activity = try await wallet.payeeActivity()
                var credited = false
                for sale in activity where sale.status == .proofReceived {
                    credited = await creditProof(sale, wallet: wallet) || credited
                }
                if credited {
                    activity = try await wallet.payeeActivity()
                }
                for sale in activity {
                    guard let hash = sale.requestHash?.hex, outgoing[hash] != nil else { continue }
                    if payeeStatus[hash] != sale.status {
                        Self.log("payee row ref=\(outgoing[hash]?.reference ?? "?") status=\(sale.status) requestHash=\(hash)")
                    }
                    payeeStatus[hash] = sale.status
                }
            } catch {
                Self.log("payee activity unreadable: \(Self.describe(error))", level: .warn)
            }
            publishOutgoing()
        }

        /// Returns true when the payment was credited and its receipt sent.
        private func creditProof(_ sale: PaykitV2.PayeeRequest, wallet: PaykitV2.NativeWallet) async -> Bool {
            let record = sale.record.hex
            let hash = sale.requestHash?.hex
            let reference = hash.flatMap { outgoing[$0]?.reference } ?? "none"
            let tries = (unconfirmedProofs[record] ?? 0) + 1
            unconfirmedProofs[record] = tries
            if tries == 1 {
                Self.log("proof received ref=\(reference) from=\(PubkyZ32.encode(sale.payer)) record=\(record)")
            }

            let paidAtMs: UInt64?
            do {
                paidAtMs = try await wallet.verifyPayment(record: sale.record)
            } catch {
                Self.log("verify ref=\(reference) try=\(tries) not yet: \(Self.describe(error))", level: tries > 3 ? .warn : .info)
                return false
            }
            guard let paidAtMs else {
                Self.log("verify ref=\(reference) try=\(tries): not paid enough on-chain yet", level: tries > 3 ? .warn : .info)
                return false
            }
            let txid = hash.flatMap { outgoing[$0]?.address }.flatMap { method?.verifiedTxid(forAddress: $0) }
            Self.log("verified ref=\(reference) txid=\(txid ?? "unknown") paidAtMs=\(paidAtMs)")

            do {
                guard let receipt = try await wallet.confirmPayment(record: sale.record, details: nil) else {
                    Self.log("confirm ref=\(reference) gave no receipt (unconfirmed or credited elsewhere)", level: .warn)
                    return false
                }
                unconfirmedProofs.removeValue(forKey: record)
                if let hash {
                    outgoing[hash]?.txid = txid
                    outgoing[hash]?.receiptMsgId = receipt
                    saveOutgoing()
                }
                do {
                    try await wallet.flush()
                } catch {
                    Self.log("outbox flush after the receipt failed: \(Self.describe(error))", level: .warn)
                }
                Self.log("receipt sent ref=\(reference) txid=\(txid ?? "unknown") receipt=\(receipt)")
                return true
            } catch {
                Self.log("confirm ref=\(reference) failed: \(Self.describe(error))", level: .warn)
                return false
            }
        }

        private func checkDeliveries(_ wallet: PaykitV2.NativeWallet) async {
            let undelivered = outgoing.filter { !$0.value.delivered }
            guard !undelivered.isEmpty else { return }
            do {
                try await wallet.flush()
            } catch {
                Self.log("outbox flush failed: \(Self.describe(error))", level: .warn)
            }
            for (hash, entry) in undelivered {
                guard let delivery = try? await wallet.messageDelivery(msgId: entry.msgId) else { continue }
                if case .accepted = delivery {
                    outgoing[hash]?.delivered = true
                    Self.log("request delivered ref=\(entry.reference) msg=\(entry.msgId)")
                }
            }
            saveOutgoing()
        }

        private var hasUnconfirmedProofs: Bool {
            // Try every 3 s for a minute; after that the normal 20 s rounds keep trying.
            unconfirmedProofs.values.contains { $0 < 20 }
        }

        private func uniqueReference(_ base: String) -> String {
            let taken = Set(outgoing.values.map(\.reference))
            let clipped = String(base.prefix(200))
            guard taken.contains(clipped) else { return clipped }
            var counter = 2
            while taken.contains("\(clipped) (\(counter))") {
                counter += 1
            }
            return "\(clipped) (\(counter))"
        }

        private static func generatedReference() -> String {
            let code = String(format: "%04X", UInt16.random(in: .min ... .max))
            return "Request \(code)"
        }

        private func outgoingRow(_ hash: String) -> PaykitV2OutgoingRequest? {
            guard let entry = outgoing[hash] else { return nil }
            let status: PaykitV2OutgoingRequest.Status = switch payeeStatus[hash] {
            case .requested, nil: .requested
            case .accepted: .accepted
            case .proofReceived: .proofReceived
            case .receipted: .receipted
            case .rejected: .rejected
            case .cancelled: .cancelled
            case .other: .other
            }
            return PaykitV2OutgoingRequest(
                id: hash,
                reference: entry.reference,
                note: entry.note,
                payer: entry.payer,
                sats: entry.sats,
                address: entry.address,
                createdAt: Date(timeIntervalSince1970: TimeInterval(entry.createdAtMs) / 1000),
                expiresAt: entry.expiresAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
                delivered: entry.delivered,
                status: status,
                txid: entry.txid
            )
        }

        private func publishOutgoing() {
            let rows = outgoing.keys.compactMap(outgoingRow).sorted { $0.createdAt > $1.createdAt }
            Task { @MainActor in
                PaykitV2DemoState.shared.apply(outgoingRequests: rows)
            }
        }

        private static func readOutgoing(_ url: URL?) -> [String: OutgoingEntry] {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return [:] }
            do {
                return try JSONDecoder().decode([String: OutgoingEntry].self, from: Data(contentsOf: url))
            } catch {
                log("outgoing.json unreadable, starting empty: \(error)", level: .warn)
                return [:]
            }
        }

        private func saveOutgoing() {
            guard let outgoingURL else { return }
            do {
                try JSONEncoder().encode(outgoing).write(to: outgoingURL, options: [.atomic, .completeFileProtection])
            } catch {
                Self.log("outgoing.json not written: \(error)", level: .warn)
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
                    await tendContacts()
                    await tendPayeeActivity()
                    // While a contact has not admitted Bitkit yet, wait less, so the outbox retries the probe soon after.
                    // While a proof waits for its transaction to show in Esplora, wait less too, so the request turns
                    // paid within seconds.
                    let wake = try await wallet.feedWait(seconds: hasOpenProbes || hasUnconfirmedProofs ? 3 : 20)
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
                    if case let .messageReceived(_, _, _, _, sender) = event.data {
                        noteMessage(from: sender)
                    }
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

        private static func describe(_ delivery: PaykitV2.MessageDelivery) -> String {
            let mirror = Mirror(reflecting: delivery)
            return mirror.children.first?.label ?? String(describing: delivery)
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
