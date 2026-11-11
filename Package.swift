// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "BSDetector",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "BSDetector")],  // needs macOS 26 at runtime (SpeechAnalyzer)
    swiftLanguageModes: [.v5]
)
