// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Meercat",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Meercat")],
    swiftLanguageModes: [.v5]
)
