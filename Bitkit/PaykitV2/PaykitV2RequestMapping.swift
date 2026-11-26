#if DEBUG
    import Foundation
    import Paykit

    /// Demo: maps Paykit v0.2 one-time requests (those Bitkit sent and those contacts sent Bitkit) onto Bitkit's own
    /// request model, so the existing request cards, the Payments list and the request detail screen show them unchanged.
    ///
    /// This file imports Paykit v0.1 (for `PaymentRequestLifecycleState`) and not `PaykitV2`; the v0.2 side hands over
    /// the plain `PaykitV2OutgoingRequest` and `PaykitV2IncomingRequest`.
    extension PaykitPaymentRequest {
        init(paykitV2Outgoing row: PaykitV2OutgoingRequest) {
            let lifecycleState: Paykit.PaymentRequestLifecycleState = switch row.status {
            case .requested: .proposed
            case .accepted: .accepted
            case .proofReceived, .receipted: .proofSubmitted
            case .rejected: .rejected
            case .cancelled: .canceled
            case .other: .unknown
            }
            let isPaid = row.status == .proofReceived || row.status == .receipted
            self.init(
                // The reference is unique among Bitkit's requests and is what the payer sees, so recording scripts can
                // find the row by the note they typed (`PaymentRequestRow-<note>-one-time`).
                paymentRequestId: row.reference,
                counterparty: PubkyPublicKeyFormat.normalized(row.payer) ?? row.payer,
                proposalStreamItemId: nil,
                amount: PaykitAmount(asset: .btc, atomic: row.sats),
                paymentReference: row.reference,
                pricing: PaykitRequestPricing(conversion: nil, deadline: nil),
                note: row.note,
                createdAt: row.createdAt,
                expiresAt: row.expiresAt,
                paymentDeadline: nil,
                acceptedPaymentEndpointIdentifiers: [PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue],
                deliveryStatus: row.delivered ? .sent : .queued,
                direction: .outgoing,
                lifecycleState: lifecycleState,
                billingPeriod: nil,
                paymentProofKind: isPaid ? .onchain : nil,
                paymentProofEventId: nil
            )
            isReceipted = row.status == .receipted
        }

        /// A request a contact sent Bitkit: open ones list as pending (Pay / Dismiss), the rest in the history.
        init(paykitV2Incoming row: PaykitV2IncomingRequest) {
            let lifecycleState: Paykit.PaymentRequestLifecycleState = switch row.status {
            case .open: .proposed
            case .paying: .accepted
            case .paid, .receipted: .proofSubmitted
            case .rejected: .rejected
            case .cancelled: .canceled
            case .expired: .proposalExpired
            case .other: .unknown
            }
            let isPaid = row.status == .paid || row.status == .receipted
            self.init(
                // The payee's reference is what Bitkit shows as the note, and the row's ID
                // (`PaymentRequestPay-<reference>`), so recording scripts can find it.
                paymentRequestId: row.reference,
                counterparty: PubkyPublicKeyFormat.normalized(row.payee) ?? row.payee,
                proposalStreamItemId: nil,
                amount: PaykitAmount(asset: .btc, atomic: row.sats),
                paymentReference: row.reference,
                pricing: PaykitRequestPricing(conversion: nil, deadline: nil),
                note: row.reference,
                createdAt: row.receivedAt,
                expiresAt: row.expiresAt,
                paymentDeadline: nil,
                acceptedPaymentEndpointIdentifiers: [
                    PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue,
                    PublicPaykitService.MethodId.regtestOnchainP2tr.rawValue,
                ],
                deliveryStatus: nil,
                direction: .incoming,
                lifecycleState: lifecycleState,
                billingPeriod: nil,
                paymentProofKind: isPaid ? .onchain : nil,
                paymentProofEventId: nil
            )
            isReceipted = row.status == .receipted
        }
    }
#endif
