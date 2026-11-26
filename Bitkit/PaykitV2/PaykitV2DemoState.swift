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
        /// One-time requests Bitkit sent, newest first.
        @Published private(set) var outgoingRequests: [PaykitV2OutgoingRequest] = []

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

        func apply(outgoingRequests: [PaykitV2OutgoingRequest]) {
            if self.outgoingRequests != outgoingRequests {
                self.outgoingRequests = outgoingRequests
            }
        }

        /// Sends a one-time request for `sats` to a saved contact, to be paid to a fresh on-chain address.
        static func sendRequest(
            to publicKey: String,
            sats: UInt64,
            note: String,
            expiresAt: Date?
        ) async throws -> PaykitV2OutgoingRequest {
            try await PaykitV2Service.shared.sendRequest(to: publicKey, sats: sats, note: note, expiresAt: expiresAt)
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
