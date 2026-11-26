#if DEBUG
    import Foundation

    /// Demo: how far Bitkit and a saved contact have admitted each other on Paykit v0.2.
    enum PaykitV2ContactConnection: Equatable, Sendable {
        /// Bitkit allowed the contact; no evidence yet that the contact allowed Bitkit.
        case waiting
        /// Both sides allowed each other: Bitkit allowed the contact, and the contact's inbox accepted a message from
        /// Bitkit, or the contact wrote to Bitkit (which grants Bitkit a reply).
        case connected
    }

    /// Demo: which Private Payment Lists Bitkit and a connected contact shared with each other.
    struct PaykitV2PrivateDetails: Equatable, Sendable {
        /// Bitkit chose the contact as a recipient of its list (Paykit keeps sending it the current version).
        let sharedByBitkit: Bool
        /// A list from the contact arrived.
        let sharedByContact: Bool
    }

    /// Demo: a Paykit v0.2 one-time request Bitkit sent (Bitkit is the payee), as the views show it.
    struct PaykitV2OutgoingRequest: Equatable, Sendable, Identifiable {
        enum Status: String, Sendable {
            /// Sent; the payer has not paid yet.
            case requested
            /// The payer accepted it.
            case accepted
            /// The payer's proof arrived and Bitkit has not credited it yet.
            case proofReceived
            /// Bitkit verified the payment on-chain and sent its receipt: paid.
            case receipted
            case rejected
            case cancelled
            case other
        }

        /// The request hash, hex.
        let id: String
        /// The payment reference the payer sees: the user's note, or a generated one.
        let reference: String
        /// The note the user typed, if any.
        let note: String?
        /// The payer, z-base-32 without a prefix.
        let payer: String
        let sats: UInt64
        /// The fresh on-chain address the request asks to be paid to.
        let address: String
        let createdAt: Date
        let expiresAt: Date?
        /// Whether the payer's inbox accepted the request message.
        let delivered: Bool
        let status: Status
        /// The payer's transaction, once a proof arrived.
        let txid: String?
    }

    /// Demo: a Paykit v0.2 one-time request a contact sent Bitkit (Bitkit is the payer), as the views show it.
    struct PaykitV2IncomingRequest: Equatable, Sendable, Identifiable {
        enum Status: String, Sendable {
            /// Waiting for Bitkit to pay.
            case open
            /// Bitkit's payment attempt is open: sent, or its outcome is not known yet.
            case paying
            /// Paid on-chain and the proof sent; the payee's receipt has not arrived yet.
            case paid
            /// The payee confirmed the payment with a receipt.
            case receipted
            case rejected
            case cancelled
            case expired
            /// Held for the user, or a state the demo does not show.
            case other
        }

        /// The request hash, hex.
        let id: String
        /// The payment reference the payee chose; Bitkit shows it as the request's note.
        let reference: String
        /// The payee, z-base-32 without a prefix.
        let payee: String
        let sats: UInt64
        /// When Bitkit first read the request (Paykit v0.2 requests carry no creation time).
        let receivedAt: Date
        let expiresAt: Date?
        let status: Status
        /// The transaction Bitkit paid it with.
        let txid: String?
    }

    /// Demo: the Paykit v0.2 state the views show, published on the main actor by `PaykitV2Service`.
    ///
    /// This file imports neither Paykit module, so views and managers that import Paykit v0.1 can use it without name
    /// clashes. Keys are z-base-32 identities without a prefix.
    @MainActor
    final class PaykitV2DemoState: ObservableObject {
        static let shared = PaykitV2DemoState()

        /// True once the v0.2 app is enrolled or loaded and its feed loop runs.
        @Published private(set) var isReady = false
        @Published private(set) var connections: [String: PaykitV2ContactConnection] = [:]
        /// Private Payment Lists shared with and by each connected contact.
        @Published private(set) var privateDetails: [String: PaykitV2PrivateDetails] = [:]
        /// One-time requests Bitkit sent, newest first.
        @Published private(set) var outgoingRequests: [PaykitV2OutgoingRequest] = []
        /// One-time requests contacts sent Bitkit, newest first.
        @Published private(set) var incomingRequests: [PaykitV2IncomingRequest] = []

        /// Saved contacts' display names by z-base-32 identity, for toasts outside the views.
        private var contactNames: [String: String] = [:]
        /// When each request Bitkit sent turned paid while the app ran, by request hash; earlier ones are absent.
        private var paidAt: [String: Date] = [:]
        private var hasOutgoingRequests = false

        /// How long a request Bitkit sent shows "paid" before Bitkit's own "Received Bitcoin" sheet may cover it.
        static let paidCardMinimumTime: TimeInterval = 4
        /// The longest the "Received Bitcoin" sheet waits for a request that may be paid by its transaction.
        private static let receivedSheetMaximumHold: TimeInterval = 15

        /// The saved contact's display name, if the identity is a saved contact.
        func contactName(for publicKey: String) -> String? {
            PubkyZ32.decodeIdentity(publicKey).flatMap { contactNames[PubkyZ32.encode($0)] }
        }

        /// Takes the saved contacts' names, as `(publicKey, displayName)` pairs.
        func setContactNames(_ names: [(publicKey: String, name: String)]) {
            var byIdentity: [String: String] = [:]
            for (publicKey, name) in names {
                guard let identity = PubkyZ32.decodeIdentity(publicKey) else { continue }
                byIdentity[PubkyZ32.encode(identity)] = name
            }
            contactNames = byIdentity
        }

        func connection(for publicKey: String) -> PaykitV2ContactConnection? {
            guard let identity = PubkyZ32.decodeIdentity(publicKey) else { return nil }
            return connections[PubkyZ32.encode(identity)]
        }

        func apply(isReady: Bool, connections: [String: PaykitV2ContactConnection]) {
            if self.isReady != isReady {
                self.isReady = isReady
            }
            if self.connections != connections {
                self.connections = connections
            }
        }

        func privateDetails(for publicKey: String) -> PaykitV2PrivateDetails? {
            guard let identity = PubkyZ32.decodeIdentity(publicKey) else { return nil }
            return privateDetails[PubkyZ32.encode(identity)]
        }

        func apply(privateDetails: [String: PaykitV2PrivateDetails]) {
            if self.privateDetails != privateDetails {
                self.privateDetails = privateDetails
            }
        }

        func apply(outgoingRequests: [PaykitV2OutgoingRequest]) {
            if hasOutgoingRequests {
                let wasPaid = Set(self.outgoingRequests.filter { $0.status == .receipted }.map(\.id))
                for row in outgoingRequests where row.status == .receipted && !wasPaid.contains(row.id) && paidAt[row.id] == nil {
                    paidAt[row.id] = Date()
                }
            }
            hasOutgoingRequests = true
            if self.outgoingRequests != outgoingRequests {
                self.outgoingRequests = outgoingRequests
            }
        }

        /// Waits before Bitkit shows its "Received Bitcoin" sheet for `txid`, so the Sent screen's "paid" is readable
        /// first: while the request that transaction paid has shown "paid" for less than `paidCardMinimumTime`, and, up to
        /// `receivedSheetMaximumHold`, while a request Bitkit sent still waits for a proof (the wallet can see the
        /// transaction before the payer's proof arrives). Returns at once for any other transaction.
        func holdReceivedSheet(txid: String) async {
            let deadline = Date().addingTimeInterval(Self.receivedSheetMaximumHold)
            while Date() < deadline {
                if let row = outgoingRequests.first(where: { $0.txid == txid }), row.status == .receipted {
                    guard let paidAt = paidAt[row.id] else { return }
                    let remaining = paidAt.addingTimeInterval(Self.paidCardMinimumTime).timeIntervalSinceNow
                    if remaining > 0 {
                        try? await Task.sleep(for: .seconds(remaining))
                    }
                    return
                }
                let awaitingProof = outgoingRequests.contains { row in
                    row.txid == txid || (row.txid == nil && [.requested, .accepted, .proofReceived].contains(row.status))
                }
                guard awaitingProof else { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        func apply(incomingRequests: [PaykitV2IncomingRequest]) {
            if self.incomingRequests != incomingRequests {
                self.incomingRequests = incomingRequests
            }
        }

        /// Pays a contact's request on-chain from Bitkit's wallet and sends the proof. Returns the request as it stands
        /// afterwards: `paid` (or `receipted`), or `paying` when the payment's outcome is not known yet.
        static func payRequest(id: String) async throws -> PaykitV2IncomingRequest {
            try await PaykitV2Service.shared.payRequest(hash: id)
        }

        /// Declines a contact's request; the contact sees it cancelled.
        static func declineRequest(id: String) async throws {
            try await PaykitV2Service.shared.declineRequest(hash: id)
        }

        /// Sends a one-time request for `sats` to a saved contact, to be paid to a fresh on-chain address, or with
        /// `toPrivateDetails` to the Private Payment List Bitkit shared with the contact.
        static func sendRequest(
            to publicKey: String,
            sats: UInt64,
            note: String,
            expiresAt: Date?,
            toPrivateDetails: Bool = false
        ) async throws -> PaykitV2OutgoingRequest {
            try await PaykitV2Service.shared.sendRequest(
                to: publicKey,
                sats: sats,
                note: note,
                expiresAt: expiresAt,
                toPrivateDetails: toPrivateDetails
            )
        }

        /// Hands the saved contacts to the v0.2 host, which admits each one (`allowConnect`) once per process.
        static func savedContactsChanged(_ publicKeys: [String]) {
            guard PaykitV2Demo.isEnabled else { return }
            Task { await PaykitV2Service.shared.setSavedContacts(publicKeys) }
        }

        /// Admits a contact the user just saved, without waiting for the saved contacts to be read again.
        static func contactAdded(_ publicKey: String) {
            guard PaykitV2Demo.isEnabled else { return }
            Task { await PaykitV2Service.shared.addContact(publicKey) }
        }
    }
#endif
