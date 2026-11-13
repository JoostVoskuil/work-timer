// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WorkTimer",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WorkTimerCore", targets: ["WorkTimerCore"])],
    targets: [
        .target(name: "WorkTimerCore"),
        .testTarget(name: "WorkTimerCoreTests", dependencies: ["WorkTimerCore"],
                    // Command Line Tools ship the Swift Testing macro plugin outside the default search path.
                    swiftSettings: [.unsafeFlags(["-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])]),
        .executableTarget(name: "WorkTimerApp", dependencies: ["WorkTimerCore"]),
    ]
)
