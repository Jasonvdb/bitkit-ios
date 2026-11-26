// swift-tools-version: 5.9
// Paykit v0.2, built under the names PaykitV2 / PaykitV2FFI so it can sit beside Paykit v0.1 in one app.
// The binary framework and the generated Swift bindings are not committed. Run scripts/fetch-paykit-v2.sh
// to copy them in from a local build. The framework has an arm64 iOS simulator slice only.
import PackageDescription

let package = Package(
    name: "PaykitV2",
    platforms: [.iOS(.v15)],
    products: [.library(name: "PaykitV2", targets: ["PaykitV2"])],
    targets: [
        .binaryTarget(name: "PaykitV2FFI", path: "PaykitV2FFI.xcframework"),
        .target(name: "PaykitV2", dependencies: ["PaykitV2FFI"], path: "Sources/PaykitV2"),
    ],
    swiftLanguageVersions: [.v5]
)
