// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetRec",
    platforms: [
        // CoreAudio process taps (CATapDescription) need 14.2; 14.4 avoids
        // early tap bugs and matches Apple's AudioCap sample baseline.
        .macOS("14.4")
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0")
    ],
    targets: [
        .executableTarget(
            name: "MeetRec",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            linkerSettings: [
                // Embed Info.plist into the bare binary so `swift run` gets
                // the same app identity (and, later, usage descriptions) as
                // the assembled MeetRec.app bundle (see Makefile).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist",
                ])
            ]
        )
    ]
)
