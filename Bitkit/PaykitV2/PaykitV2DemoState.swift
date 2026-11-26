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
