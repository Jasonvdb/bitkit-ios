import Foundation

/// Demo: whether Bitkit runs the Paykit v0.2 demo, where v0.2 owns contact admission and the v0.1 Paykit background work
/// that would compete with it is switched off.
///
/// On only in Debug builds on the local regtest (`Env.usesLocalRegtest`); a Release build compiles the guards that read it
/// as constant false.
enum PaykitV2Demo {
    static var isEnabled: Bool {
        #if DEBUG
            Env.usesLocalRegtest
        #else
            false
        #endif
    }

    #if DEBUG
        /// Demo test hook: `PAYKIT_V2_DEMO_SLOW_V01_MS` makes every Paykit v0.1 SDK operation (the ones that can reach the
        /// Pubky staging Homeserver) wait this long first, to check that no demo screen waits on staging. Unset or 0 adds
        /// nothing.
        private static let slowV01Delay: Duration? = {
            guard Env.usesLocalRegtest,
                  let raw = ProcessInfo.processInfo.environment["PAYKIT_V2_DEMO_SLOW_V01_MS"],
                  let milliseconds = Int(raw.trimmingCharacters(in: .whitespaces)), milliseconds > 0
            else { return nil }
            return .milliseconds(milliseconds)
        }()

        /// Waits as long as `PAYKIT_V2_DEMO_SLOW_V01_MS` says before a v0.1 SDK operation; returns at once when unset.
        static func simulateSlowV01() async {
            guard let slowV01Delay else { return }
            try? await Task.sleep(for: slowV01Delay)
        }
    #endif
}
