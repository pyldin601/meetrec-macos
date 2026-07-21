// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetRec",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MeetRec",
            linkerSettings: [
                // Embed Info.plist into the bare binary so `swift run` also
                // gets a working microphone usage description; the assembled
                // MeetRec.app bundle (see Makefile) carries the real one.
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
