// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "capcap",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "capcap",
            path: "capcap",
            exclude: ["App/Info.plist", "Assets.xcassets"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreImage"),
            ]
        )
    ]
)
