#if DEBUG
    import Foundation

    /// Demo: launch settings of the Paykit v0.2 host, read from the process environment.
    ///
    /// The simulator passes `SIMCTL_CHILD_<NAME>` variables of `xcrun simctl launch` to the app as `<NAME>`. Every
    /// value has a default that matches the local demo services, so a launch without any variable works too.
    ///
    /// | Variable | Default |
    /// |---|---|
    /// | `PAYKIT_V2_HOMESERVER` | `fake` (`staging` uses Pubky staging with Bitkit's root session) |
    /// | `PAYKIT_V2_FAKE_HOMESERVER_URL` | `http://127.0.0.1:18590` |
    /// | `PAYKIT_V2_STAGING_HOMESERVER_URL` | `https://homeserver.staging.pubky.app` |
    /// | `PAYKIT_V2_DISPATCH_ORIGIN` | `https://localhost:18580` (the origin the Dispatch requests are signed for) |
    /// | `PAYKIT_V2_DISPATCH_LISTENER` | `http://127.0.0.1:18580` (where they are sent, plain HTTP on loopback) |
    /// | `PAYKIT_V2_ESPLORA_URL` | `http://127.0.0.1:3000/api` (the regtest Esplora API the on-chain method verifies proofs with) |
    struct PaykitV2Config {
        enum HomeserverBackend: String {
            case fake
            case staging
        }

        let homeserverBackend: HomeserverBackend
        let fakeHomeserverUrl: URL
        let stagingHomeserverUrl: URL
        let dispatchOrigin: String
        let dispatchListener: String
        let esploraUrl: URL

        static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> PaykitV2Config {
            func value(_ key: String) -> String? {
                let trimmed = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }

            let backend = value("PAYKIT_V2_HOMESERVER").flatMap { HomeserverBackend(rawValue: $0.lowercased()) } ?? .fake
            return PaykitV2Config(
                homeserverBackend: backend,
                fakeHomeserverUrl: value("PAYKIT_V2_FAKE_HOMESERVER_URL").flatMap(URL.init(string:))
                    ?? URL(string: "http://127.0.0.1:18590")!,
                stagingHomeserverUrl: value("PAYKIT_V2_STAGING_HOMESERVER_URL").flatMap(URL.init(string:))
                    ?? URL(string: "https://homeserver.staging.pubky.app")!,
                dispatchOrigin: value("PAYKIT_V2_DISPATCH_ORIGIN") ?? "https://localhost:18580",
                dispatchListener: value("PAYKIT_V2_DISPATCH_LISTENER") ?? "http://127.0.0.1:18580",
                esploraUrl: value("PAYKIT_V2_ESPLORA_URL").flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:3000/api")!
            )
        }
    }
#endif
