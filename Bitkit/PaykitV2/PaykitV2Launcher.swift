#if DEBUG
    import BitkitCore
    import Foundation

    /// Demo: starts Bitkit's Paykit v0.2 host in a Debug local-regtest build, once per process.
    ///
    /// The identity is the Pubky key Bitkit already uses: the stored `pubkySecretKey` when the user created a profile,
    /// otherwise the same key derived from the wallet's seed (what Bitkit stores when it creates the profile). It does
    /// not sign up, sign in or change Bitkit's v0.1 Pubky state.
    ///
    /// This file imports BitkitCore (for the staging root session) and neither Paykit module; the v0.2 code lives in
    /// files that import only `PaykitV2`.
    enum PaykitV2Launcher {
        static var isEnabled: Bool {
            PaykitV2Demo.isEnabled
        }

        static func startIfEnabled(walletIndex: Int = 0) {
            guard isEnabled else { return }
            Task.detached(priority: .utility) {
                do {
                    let launch = try makeLaunch(walletIndex: walletIndex)
                    await PaykitV2Service.shared.start(launch)
                } catch {
                    PaykitV2Service.log("not started: \(error)", level: .error)
                }
            }
        }

        private static func makeLaunch(walletIndex: Int) throws -> PaykitV2Service.Launch {
            let (secretHex, source) = try identitySecretHex(walletIndex: walletIndex)
            let secret = secretHex.hexaData
            guard secret.count == 32 else { throw LaunchError.badIdentitySecret }

            let publicKey = try PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: secretHex)
            guard let identity = PubkyZ32.decodeIdentity(publicKey) else { throw LaunchError.badIdentitySecret }
            let identityZ32 = PubkyZ32.encode(identity)
            PaykitV2Service.log("identity=\(identityZ32) source=\(source)")

            let directory = Env.appStorageUrl
                .appendingPathComponent(Env.networkName)
                .appendingPathComponent("wallet\(walletIndex)/paykit-v2/\(identityZ32)")

            return PaykitV2Service.Launch(
                identitySecret: secret,
                identityZ32: identityZ32,
                directory: directory,
                config: PaykitV2Config.fromEnvironment(),
                stagingSignIn: { try await BitkitCore.pubkySignIn(secretKeyHex: secretHex) }
            )
        }

        private static func identitySecretHex(walletIndex: Int) throws -> (String, String) {
            if let stored = try Keychain.loadString(key: .pubkySecretKey), !stored.isEmpty {
                return (stored, "profile key")
            }
            guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)), !mnemonic.isEmpty else {
                throw LaunchError.noWalletSeed
            }
            return (try PubkyService.derivePubkySecretKey(mnemonic: mnemonic), "wallet seed")
        }

        enum LaunchError: Error {
            case noWalletSeed
            case badIdentitySecret
        }
    }
#endif
