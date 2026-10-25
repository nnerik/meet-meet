// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetMeetCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "MeetMeetCore", targets: ["MeetMeetCore"])],
    targets: [
        .target(name: "MeetMeetCore"),
        .testTarget(name: "MeetMeetCoreTests", dependencies: ["MeetMeetCore"]),
    ]
)
