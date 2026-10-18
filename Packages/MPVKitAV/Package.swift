// swift-tools-version:5.9
// libmpv из форка MPVKit от Streamyfin: в нём есть vo=avfoundation (вывод в AVSampleBufferDisplayLayer —
// нужен для PiP и HDR на iPhone) и обычный vo=gpu-next. Один статический MPVKit.xcframework.
// https://github.com/streamyfin/MPVKit/releases/tag/0.41.0-av5

import PackageDescription

let package = Package(
    name: "MPVKitAV",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MPVKitAV", targets: ["MPVKitAV"]),
    ],
    targets: [
        .target(
            name: "MPVKitAV",
            dependencies: ["MPVKit"],
            path: "Sources/MPVKitAV",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
                .linkedLibrary("resolv"),
                .linkedLibrary("expat"),
            ]
        ),
        .binaryTarget(
            name: "MPVKit",
            url: "https://github.com/streamyfin/MPVKit/releases/download/0.41.0-av5/MPVKit.xcframework.zip",
            checksum: "80a79fbb34b1a3ae84744fe7bb9d365d2a006a5f617460933b7ce777251d3618"
        ),
    ]
)
