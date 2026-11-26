#if DEBUG
    import Foundation
    import PaykitV2

    /// Demo: the regtest on-chain payment method Bitkit declares to Paykit v0.2.
    ///
    /// Bitkit is paid here: `verify` checks a payer's proof against the regtest Esplora API and `settlementId` names the
    /// transaction. Paying is still a stub: `selectEndpoints` refuses every candidate and `pay` answers `NotSubmitted`
    /// (authoritative: nothing was sent), so `payment(attemptId:)` can honestly answer nil.
    ///
    /// Identifiers, as the demo contract fixes them: Bitkit receives on `btc-regtest-p2wpkh` and pays both
    /// `btc-regtest-p2wpkh` and `btc-regtest-p2tr`. Payload `{"value":"<address>"}`, asset `btc`, 8 fraction digits,
    /// proof `{"txid":"<64 lowercase hex>"}`, settlement ID the 32 txid bytes.
    ///
    /// Demo shortcuts (never for real funds): an unconfirmed transaction is accepted (0-conf), so a replaced
    /// transaction would still be credited; the Esplora server is trusted as it answers, over plain HTTP on loopback.
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

        private let esploraUrl: URL
        private let session: URLSession
        /// The transaction that last verified for each address. Paykit calls the method from its own threads.
        private let lock = NSLock()
        private var verifiedTxids: [String: String] = [:]

        /// The transaction whose proof verified for one of Bitkit's request addresses, for logs and the UI.
        func verifiedTxid(forAddress address: String) -> String? {
            lock.withLock { verifiedTxids[address] }
        }

        init(esploraUrl: URL) {
            self.esploraUrl = esploraUrl
            let configuration = URLSessionConfiguration.ephemeral
            // Paykit gives a lookup 10 s; stay under it.
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 8
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: configuration)
        }

        // MARK: - Paying (B5)

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
            guard let address = proof.payload.flatMap(Self.address(fromPayload:)) else {
                PaykitV2Service.log("verify refused: no address payload for txid=\(txid)", level: .warn)
                return nil
            }

            let transaction = try await fetchTransaction(txid)
            let received = transaction.vout
                .filter { $0.scriptpubkeyAddress == address }
                .reduce(UInt64(0)) { $0 + $1.value }
            let confirmed = transaction.status.confirmed
            PaykitV2Service.log(
                "verify txid=\(txid) address=\(address) received=\(received) wanted=\(wanted) confirmed=\(confirmed)"
            )
            guard received >= wanted else { return nil }
            lock.withLock { verifiedTxids[address] = txid }

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
