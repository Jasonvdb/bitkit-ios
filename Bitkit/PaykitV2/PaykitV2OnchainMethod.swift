#if DEBUG
    import Foundation
    import LDKNode
    import PaykitV2

    /// Demo: the regtest on-chain payment method Bitkit declares to Paykit v0.2.
    ///
    /// Bitkit is paid here: `verify` checks a payer's proof against the regtest Esplora API and `settlementId` names the
    /// transaction. Bitkit pays here too: `pay` sends from Bitkit's LDK on-chain wallet at a fixed fee rate, and every
    /// attempt is kept in an attempt journal (`payments.json`), so `payment(attemptId:)` answers for it after a restart
    /// and a second `pay` for the same attempt never sends twice.
    ///
    /// Identifiers, as the demo contract fixes them: Bitkit receives on `btc-regtest-p2wpkh` and pays both
    /// `btc-regtest-p2wpkh` and `btc-regtest-p2tr`. Payload `{"value":"<address>"}`, asset `btc`, 8 fraction digits,
    /// proof `{"txid":"<64 lowercase hex>"}`, settlement ID the 32 txid bytes.
    ///
    /// Demo shortcuts (never for real funds): an unconfirmed transaction is accepted (0-conf), so a replaced
    /// transaction would still be credited; the Esplora server is trusted as it answers, over plain HTTP on loopback;
    /// the fee rate is fixed (`feeRateSatsPerVbyte`), so no fee feed is needed; an address may be paid more than once
    /// (a browser wallet's boarding address is stable).
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

        /// The fee rate of every payment, sat/vB. Fixed, so the fee is bounded and no fee feed is asked; the local
        /// regtest relays anything above zero.
        static let feeRateSatsPerVbyte: UInt32 = 2

        private let esploraUrl: URL
        private let session: URLSession
        /// Paykit calls the method from its own threads; this lock guards the state below and the journal file.
        private let lock = NSLock()
        /// The transaction that last verified for each address.
        private var verifiedTxids: [String: String] = [:]
        /// The address and transaction of the proof that verified last.
        private var lastVerified: (address: String, txid: String)?
        /// Every address Bitkit put in its Private Payment List, for proofs that come without a payload.
        private var listAddresses: Set<String> = []

        /// Takes the addresses Bitkit's Private Payment List has held: the current one and earlier ones, which a payer
        /// may still pay from an older copy of the list.
        func setListAddresses(_ addresses: Set<String>) {
            lock.withLock { listAddresses = addresses }
        }
        /// The attempt journal, by attempt ID, kept in `journalURL`.
        private var journal: [String: JournalEntry]
        private let journalURL: URL

        /// The transaction whose proof verified for one of Bitkit's request addresses, for logs and the UI.
        func verifiedTxid(forAddress address: String) -> String? {
            lock.withLock { verifiedTxids[address] }
        }

        /// The address and transaction of the proof that verified last. The host reads it right after
        /// `verifyPayment` returns a time, to learn which of Bitkit's addresses (a request's own, or the Private Payment
        /// List's) was paid.
        func lastVerification() -> (address: String, txid: String)? {
            lock.withLock { lastVerified }
        }

        /// The transaction Bitkit sent for a payment attempt, once it was handed to the network.
        func sentTxid(forAttempt attemptId: String) -> String? {
            lock.withLock { journal[attemptId]?.txid }
        }

        init(esploraUrl: URL, journalURL: URL) {
            self.esploraUrl = esploraUrl
            self.journalURL = journalURL
            journal = Self.readJournal(journalURL)
            let configuration = URLSessionConfiguration.ephemeral
            // Paykit gives a lookup 10 s; stay under it.
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 8
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: configuration)
        }

        // MARK: - Paying

        /// One payment attempt as the journal keeps it. Written before the wallet is asked to send, so a crash in
        /// between leaves `submitting`, which is never sent again and answers "pending" (it may have gone out).
        private struct JournalEntry: Codable {
            enum State: String, Codable {
                /// About to be handed to the wallet; it may have gone out.
                case submitting
                /// Handed to the network, outcome not known yet (the broadcast did not answer).
                case pending
                /// Accepted by the network: paid.
                case paid
                /// Refused before or at broadcast: nothing moved.
                case failed
            }

            var state: State
            var endpoint: String
            var address: String
            var sats: UInt64
            var paymentReference: String?
            var createdAtMs: UInt64
            var txid: String?
            var paidAtMs: UInt64?
        }

        /// Payable: a supported identifier whose payload is a regtest address of the matching type (`bcrt1q` for
        /// P2WPKH, `bcrt1p` for P2TR). Every other candidate is refused as not submitted.
        func selectEndpoints(candidates: [PaykitV2.EndpointCandidate], amount: PaykitV2.Amount?) throws -> PaykitV2.SelectedEndpoints {
            var payable: [UInt32] = []
            var failures: [PaykitV2.EndpointFailure] = []
            for candidate in candidates {
                if let address = Self.address(fromPayload: candidate.payload),
                   Self.identifier(forAddress: address) == candidate.identifier
                {
                    payable.append(candidate.id)
                } else {
                    failures.append(PaykitV2.EndpointFailure(
                        id: candidate.id,
                        error: .NotSubmitted(reason: "not a regtest on-chain endpoint Bitkit pays")
                    ))
                }
            }
            return PaykitV2.SelectedEndpoints(payable: payable, failures: failures)
        }

        /// An address fixes no amount: exactly the amount asked is sent, the fee on top.
        func transfer(endpoint: String, payload: String, amount: PaykitV2.Amount) throws -> PaykitV2.MethodTransfer {
            try PaykitV2.MethodTransfer(amount: amount)
        }

        /// Sends the amount to the payload's address from Bitkit's LDK on-chain wallet at the fixed fee rate.
        ///
        /// Idempotent on the attempt ID: an attempt already in the journal is answered from it and never sent again.
        func pay(payment: PaykitV2.MethodPayment) async throws -> PaykitV2.MethodOutcome {
            if let earlier = lock.withLock({ journal[payment.attemptId] }) {
                PaykitV2Service.log("pay attempt=\(payment.attemptId) already journaled state=\(earlier.state.rawValue)")
                return try await outcome(of: earlier, attemptId: payment.attemptId)
            }
            guard let address = Self.address(fromPayload: payment.payload),
                  Self.identifier(forAddress: address) == payment.endpoint
            else {
                throw PaykitV2.MethodError.NotSubmitted(reason: "the endpoint is not a regtest address Bitkit pays")
            }
            guard payment.amount.asset == "btc", let sats = PaykitV2Sats.fromBtc(payment.amount.value), sats > 0 else {
                throw PaykitV2.MethodError.NotSubmitted(reason: "the amount is not a positive BTC amount")
            }

            var entry = JournalEntry(
                state: .submitting,
                endpoint: payment.endpoint,
                address: address,
                sats: sats,
                paymentReference: payment.paymentReference,
                createdAtMs: Self.nowMs(),
                txid: nil,
                paidAtMs: nil
            )
            do {
                try record(entry, for: payment.attemptId)
            } catch {
                // Nothing was sent: an attempt the journal cannot hold is not started.
                throw PaykitV2.MethodError.NotSubmitted(reason: "the attempt journal could not be written")
            }
            PaykitV2Service.log(
                "pay attempt=\(payment.attemptId) endpoint=\(payment.endpoint) address=\(address) sats=\(sats) "
                    + "feeRate=\(Self.feeRateSatsPerVbyte)"
            )

            let result: OnchainSendResult
            do {
                result = try await LightningService.shared.send(
                    address: address,
                    sats: sats,
                    satsPerVbyte: Self.feeRateSatsPerVbyte
                )
            } catch {
                // LDK refused to build or sign the transaction (not enough funds, node not running): nothing went out.
                entry.state = .failed
                try? record(entry, for: payment.attemptId)
                PaykitV2Service.log("pay attempt=\(payment.attemptId) refused by the wallet: \(error)", level: .warn)
                throw PaykitV2.MethodError.NotSubmitted(reason: "the wallet could not send the payment")
            }

            switch result {
            case let .accepted(txid):
                entry.state = .paid
                entry.txid = txid
                entry.paidAtMs = Self.nowMs()
                try? record(entry, for: payment.attemptId)
                PaykitV2Service.log("pay attempt=\(payment.attemptId) sent txid=\(txid)")
                Task {
                    // The first sync can run before the Electrum server indexed the new transaction; the second one
                    // lists the send on Home without waiting for the next periodic sync (about 10 s).
                    try? await LightningService.shared.sync()
                    try? await Task.sleep(for: .milliseconds(1500))
                    try? await LightningService.shared.sync()
                }
                return .paid(proofJson: Self.proof(txid: txid), paidAtMs: entry.paidAtMs)
            case let .rejected(txid, reason):
                entry.state = .failed
                entry.txid = txid
                try? record(entry, for: payment.attemptId)
                PaykitV2Service.log("pay attempt=\(payment.attemptId) broadcast rejected txid=\(txid): \(reason)", level: .warn)
                throw PaykitV2.MethodError.NotSubmitted(reason: "the network refused the transaction")
            case let .unknown(txid):
                entry.state = .pending
                entry.txid = txid
                try? record(entry, for: payment.attemptId)
                PaykitV2Service.log("pay attempt=\(payment.attemptId) broadcast outcome unknown txid=\(txid)", level: .warn)
                return .pending
            }
        }

        /// The journal's answer for an attempt: nil for one this method never started, pending while it may still go
        /// out, paid with the same proof once it went out.
        func payment(attemptId: String) async throws -> PaykitV2.MethodOutcome? {
            guard let entry = lock.withLock({ journal[attemptId] }) else { return nil }
            return try await outcome(of: entry, attemptId: attemptId)
        }

        private func outcome(of entry: JournalEntry, attemptId: String) async throws -> PaykitV2.MethodOutcome {
            switch entry.state {
            case .paid:
                guard let txid = entry.txid else { return .pending }
                return .paid(proofJson: Self.proof(txid: txid), paidAtMs: entry.paidAtMs)
            case .failed:
                return .failed
            case .submitting:
                return .pending
            case .pending:
                // The broadcast did not answer: the transaction counts as paid once Esplora knows it.
                guard let txid = entry.txid, (try? await fetchTransaction(txid)) != nil else { return .pending }
                var paid = entry
                paid.state = .paid
                paid.paidAtMs = Self.nowMs()
                try? record(paid, for: attemptId)
                PaykitV2Service.log("pay attempt=\(attemptId) txid=\(txid) found in esplora, paid")
                return .paid(proofJson: Self.proof(txid: txid), paidAtMs: paid.paidAtMs)
            }
        }

        private func record(_ entry: JournalEntry, for attemptId: String) throws {
            try lock.withLock {
                var updated = journal
                updated[attemptId] = entry
                let data = try JSONEncoder().encode(updated)
                try data.write(to: journalURL, options: [.atomic, .completeFileProtection])
                journal = updated
            }
        }

        private static func readJournal(_ url: URL) -> [String: JournalEntry] {
            guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
            do {
                return try JSONDecoder().decode([String: JournalEntry].self, from: Data(contentsOf: url))
            } catch {
                // An unreadable journal is kept aside, not overwritten: attempts in it may have paid.
                let aside = url.appendingPathExtension("unreadable")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: url, to: aside)
                PaykitV2Service.log("payments.json unreadable, kept as \(aside.lastPathComponent): \(error)", level: .error)
                return [:]
            }
        }

        /// The proof Bitkit sends for a transaction: `{"txid":"<64 lowercase hex>"}`.
        static func proof(txid: String) -> Data {
            Data("{\"txid\":\"\(txid.lowercased())\"}".utf8)
        }

        private static func nowMs() -> UInt64 {
            UInt64(Date().timeIntervalSince1970 * 1000)
        }

        func allowanceHistory(payer: Data) async throws -> [PaykitV2.MethodHandoff]? {
            nil
        }

        // MARK: - Being paid

        /// Finds the proof's transaction in Esplora and sums every output to the payload's address (a batch transaction,
        /// such as a collaborative exit, can pay it more than once). Accepts when the sum reaches the expected amount.
        ///
        /// Returns the payment time in Unix ms: the block time once confirmed, otherwise now (0-conf is accepted).
        /// Returns nil for a proof that cannot pay this endpoint or pays too little. Throws `Unknown` while Esplora does
        /// not know the transaction yet or cannot be reached, so the host can try again.
        func verify(proof: PaykitV2.MethodProof) async throws -> UInt64? {
            guard Self.endpoints.contains(where: { $0.identifier == proof.endpoint }) else {
                PaykitV2Service.log("verify refused: endpoint \(proof.endpoint) is not on-chain regtest", level: .warn)
                return nil
            }
            guard let txid = Self.txid(fromProof: proof.proofJson) else {
                PaykitV2Service.log("verify refused: the proof carries no txid", level: .warn)
                return nil
            }
            guard proof.amount.asset == "btc", let wanted = PaykitV2Sats.fromBtc(proof.amount.value) else {
                PaykitV2Service.log("verify refused: amount \(proof.amount.value) \(proof.amount.asset) is not BTC", level: .warn)
                return nil
            }
            // A request's own endpoint comes with its payload. A payment to Bitkit's Private Payment List (a request
            // that left the destination open) comes without one, so the outputs to any address Bitkit ever put in its
            // list count.
            let targets: Set<String>
            if let payload = proof.payload {
                guard let address = Self.address(fromPayload: payload) else {
                    PaykitV2Service.log("verify refused: no address in the payload for txid=\(txid)", level: .warn)
                    return nil
                }
                targets = [address]
            } else {
                targets = lock.withLock { listAddresses }
                guard !targets.isEmpty else {
                    PaykitV2Service.log("verify refused: no payload and no list address for txid=\(txid)", level: .warn)
                    return nil
                }
            }

            let transaction = try await fetchTransaction(txid)
            let paidOutputs = transaction.vout.filter { output in
                output.scriptpubkeyAddress.map { targets.contains($0) } ?? false
            }
            let received = paidOutputs.reduce(UInt64(0)) { $0 + $1.value }
            let address = paidOutputs.first?.scriptpubkeyAddress ?? targets.sorted().joined(separator: ",")
            let confirmed = transaction.status.confirmed
            PaykitV2Service.log(
                "verify txid=\(txid) address=\(address) received=\(received) wanted=\(wanted) confirmed=\(confirmed)"
            )
            guard received >= wanted else { return nil }
            lock.withLock {
                verifiedTxids[address] = txid
                lastVerified = (address, txid)
            }

            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
            if confirmed, let blockTime = transaction.status.blockTime {
                return min(blockTime * 1000, nowMs)
            }
            return nowMs
        }

        func settlementId(endpoint: String, proofJson: Data) throws -> Data? {
            guard Self.endpoints.contains(where: { $0.identifier == endpoint }),
                  let txid = Self.txid(fromProof: proofJson)
            else { return nil }
            return Self.hexBytes(txid)
        }

        // MARK: - Esplora

        private struct EsploraTransaction: Decodable {
            struct Output: Decodable {
                let scriptpubkeyAddress: String?
                let value: UInt64

                enum CodingKeys: String, CodingKey {
                    case scriptpubkeyAddress = "scriptpubkey_address"
                    case value
                }
            }

            struct Status: Decodable {
                let confirmed: Bool
                let blockTime: UInt64?

                enum CodingKeys: String, CodingKey {
                    case confirmed
                    case blockTime = "block_time"
                }
            }

            let vout: [Output]
            let status: Status
        }

        private func fetchTransaction(_ txid: String) async throws -> EsploraTransaction {
            let url = esploraUrl.appendingPathComponent("tx").appendingPathComponent(txid)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(from: url)
            } catch {
                throw PaykitV2.MethodError.Unknown(reason: "esplora unreachable")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // 404: Esplora has not seen the transaction yet. Not a refusal: the host verifies again later.
                PaykitV2Service.log("verify txid=\(txid) esplora status=\(status), trying again later")
                throw PaykitV2.MethodError.Unknown(reason: "transaction not known to esplora yet")
            }
            do {
                return try JSONDecoder().decode(EsploraTransaction.self, from: data)
            } catch {
                throw PaykitV2.MethodError.Unknown(reason: "esplora answer unreadable")
            }
        }

        // MARK: - Wire values

        /// The proof's `txid`: 64 lowercase hex characters.
        static func txid(fromProof proofJson: Data) -> String? {
            guard let object = try? JSONSerialization.jsonObject(with: proofJson) as? [String: Any],
                  let txid = object["txid"] as? String,
                  txid.count == 64,
                  txid.allSatisfy({ ("0" ... "9").contains($0) || ("a" ... "f").contains($0) })
            else { return nil }
            return txid
        }

        /// The address in a `{"value":"<address>"}` payload, when it is a regtest address.
        static func address(fromPayload payload: String) -> String? {
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["value"] as? String,
                  value.lowercased().hasPrefix("bcrt1")
            else { return nil }
            return value
        }

        /// The payload Bitkit sends for one of its addresses.
        static func payload(forAddress address: String) -> String {
            "{\"value\":\"\(address)\"}"
        }

        /// The identifier for one of Bitkit's own addresses, by its prefix; nil for one the demo does not receive on.
        static func identifier(forAddress address: String) -> String? {
            let lowercased = address.lowercased()
            if lowercased.hasPrefix("bcrt1q") { return receiveIdentifier }
            if lowercased.hasPrefix("bcrt1p") { return boardingIdentifier }
            return nil
        }

        private static func hexBytes(_ hex: String) -> Data? {
            var bytes = Data(capacity: hex.count / 2)
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return bytes
        }
    }

    /// Demo: BTC amounts as Paykit v0.2 spells them (decimal BTC, 8 fraction digits) and as satoshis.
    enum PaykitV2Sats {
        /// `20000` -> `"0.00020000"`.
        static func toBtc(_ sats: UInt64) -> String {
            let whole = sats / 100_000_000
            let fraction = String(sats % 100_000_000)
            return "\(whole)." + String(repeating: "0", count: 8 - fraction.count) + fraction
        }

        /// `"0.0002"` -> `20000`. Nil for anything that is not a non-negative decimal with at most 8 significant
        /// fraction digits.
        static func fromBtc(_ value: String) -> UInt64? {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2, let wholePart = parts.first, !wholePart.isEmpty,
                  wholePart.allSatisfy({ ("0" ... "9").contains($0) }), let whole = UInt64(wholePart)
            else { return nil }
            var fractionText = parts.count == 2 ? String(parts[1]) : ""
            while fractionText.count > 8, fractionText.hasSuffix("0") {
                fractionText.removeLast()
            }
            guard fractionText.count <= 8, fractionText.allSatisfy({ ("0" ... "9").contains($0) }) else { return nil }
            let fraction = UInt64(fractionText + String(repeating: "0", count: 8 - fractionText.count)) ?? 0
            let (scaled, overflow) = whole.multipliedReportingOverflow(by: 100_000_000)
            guard !overflow else { return nil }
            let (total, overflowAdd) = scaled.addingReportingOverflow(fraction)
            return overflowAdd ? nil : total
        }
    }
#endif
