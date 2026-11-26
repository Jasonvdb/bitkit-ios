#if DEBUG
    import Foundation
    import Paykit

    /// Demo: at launch of a local regtest Debug build, call Paykit v0.1 and Paykit v0.2 once each and log the
    /// results under one marker, to show both Rust libraries load and run in one process.
    enum PaykitVersionsProbe {
        static let marker = "PAYKIT_V2_PROBE"

        /// The public BIP39 test mnemonic, so the v0.1 key derivation gives a known, non-secret value.
        private static let testMnemonic =
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

        static func runInBackground() {
            Task.detached(priority: .utility) {
                await run()
            }
        }

        private static func run() async {
            do {
                let receiptId = Paykit.generateReceiptId()
                let testKey = try Paykit.pubkySecretKeyFromBip39Mnemonic(mnemonicPhrase: testMnemonic)
                let testPublicKey = try Paykit.pubkyPublicKeyFromSecret(localSecretKey: testKey)
                Logger.info("\(marker) v0.1 ok: receiptId=\(receiptId) testMnemonicPubky=\(testPublicKey)", context: "PaykitProbe")
            } catch {
                Logger.error("\(marker) v0.1 failed: \(error)", context: "PaykitProbe")
            }

            do {
                let report = try await PaykitV2Probe.run()
                Logger.info(
                    "\(marker) v0.2 ok: appId=\(report.appId) appRecordPath=\(report.appRecordPath) "
                        + "requestHash=\(report.requestHash) signedRequestBytes=\(report.signedRequestBytes) "
                        + "readBackMatches=\(report.readBackMatches) storedRows=\(report.storedRows)",
                    context: "PaykitProbe"
                )
            } catch {
                Logger.error("\(marker) v0.2 failed: \(error)", context: "PaykitProbe")
            }
        }
    }
#endif
