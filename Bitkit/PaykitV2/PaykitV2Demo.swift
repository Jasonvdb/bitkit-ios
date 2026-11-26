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
}
