// swift-tools-version:5.9
// The app's engine as a command-line tool, for working on transitions without
// launching the app or a test host: `swift build -c release`, then
// `.build/release/passable-render --help`. The Xcode project (project.yml) is
// still what builds the app.
import PackageDescription

let package = Package(
    name: "PassableTools",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "passable-render",
            path: ".",
            exclude: [
                "Passable/App", "Passable/UI", "Passable/Resources",
                "Passable/Model/Session.swift", "Passable/Model/SetSession.swift", "Passable/Model/PassableFile.swift",
                "PassableTests", "ios", "tools/audit", "tools/convert-beats", "tools/convert-demucs", "tools/icon",
                "Passable.xcodeproj", "README.md", "LICENSE", "project.yml", "docs",
            ],
            sources: [
                "Passable/Analysis",
                "Passable/Audio",
                "Passable/DSP",
                "Passable/Engine",
                "Passable/Library",
                "Passable/Model/Automation.swift",
                "Passable/Model/PassableMix.swift",
                "Passable/Model/PhoneMix.swift",
                "Passable/Model/TransitionPreset.swift",
                "Passable/Separation",
                "tools/render",
            ],
            swiftSettings: [.unsafeFlags(["-Ounchecked", "-wmo"])]
        ),
    ]
)
