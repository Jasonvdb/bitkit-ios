#if DEBUG
    import Foundation
    import PaykitV2

    /// Demo: the regtest on-chain payment method Bitkit declares to Paykit v0.2.
    ///
    /// For now a stub: it receives requests and lists, but pays nothing and verifies nothing. `pay` answers
    /// `NotSubmitted` (authoritative: nothing was sent), so `payment(attemptId:)` can honestly answer nil. The real
    /// method over Bitkit's LDK on-chain wallet replaces these bodies in a later step.
    ///
    /// Identifiers, as the demo contract fixes them: Bitkit receives on `btc-regtest-p2wpkh` and pays both
    /// `btc-regtest-p2wpkh` and `btc-regtest-p2tr`. Payload `{"value":"<address>"}`, asset `btc`, 8 fraction digits.
    final class PaykitV2OnchainMethod: PaykitV2.PaymentMethod, @unchecked Sendable {
        static let receiveIdentifier = "btc-regtest-p2wpkh"
        static let boardingIdentifier = "btc-regtest-p2tr"

        static let endpoints = [
            PaykitV2.EndpointSupport(identifier: receiveIdentifier, fractionDigits: 8),
            PaykitV2.EndpointSupport(identifier: boardingIdentifier, fractionDigits: 8),
        ]

        /// `history` must be true, or `payRequest` refuses with `PaymentMethodWithoutLookup`.
        static let declaration = PaykitV2.MethodDeclaration(
            idempotent: true,
            idempotencyRetentionMs: nil,
            history: true,
            historyRetentionMs: nil,
            historySurvivesRestore: false,
            longestCompletionMs: 3_600_000,
            paymentTimeToleranceMs: 120_000
        )

        private static let notYet = "the demo on-chain method does not pay yet"

        func selectEndpoints(candidates: [PaykitV2.EndpointCandidate], amount: PaykitV2.Amount?) throws -> PaykitV2.SelectedEndpoints {
            PaykitV2.SelectedEndpoints(
                payable: [],
                failures: candidates.map { PaykitV2.EndpointFailure(id: $0.id, error: .NotSubmitted(reason: Self.notYet)) }
            )
        }

        func transfer(endpoint: String, payload: String, amount: PaykitV2.Amount) throws -> PaykitV2.MethodTransfer {
            try PaykitV2.MethodTransfer(amount: amount)
        }

        func pay(payment: PaykitV2.MethodPayment) async throws -> PaykitV2.MethodOutcome {
            throw PaykitV2.MethodError.NotSubmitted(reason: Self.notYet)
        }

        func payment(attemptId: String) async throws -> PaykitV2.MethodOutcome? {
            nil
        }

        func allowanceHistory(payer: Data) async throws -> [PaykitV2.MethodHandoff]? {
            nil
        }

        func verify(proof: PaykitV2.MethodProof) async throws -> UInt64? {
            nil
        }

        func settlementId(endpoint: String, proofJson: Data) throws -> Data? {
            nil
        }
    }
#endif
