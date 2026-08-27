// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalMPVKit",
    platforms: [
        .macOS(.v10_15), .iOS(.v13), .tvOS(.v13)
    ],
    products: [
        .library(
            name: "MPVKit",
            targets: ["MPVKit"]),
    ],
    targets: [
        .target(
            name: "MPVKit",
            dependencies: [
                "Libmpv",
                "Libavcodec", "Libavdevice", "Libavfilter", "Libavformat", "Libavutil",
                "Libswresample", "Libswscale", "Libass", "Libbluray", "Libcrypto",
                "Libdav1d", "Libdovi", "Libfreetype", "Libfribidi", "Libuavs3d",
                "Libharfbuzz", "Libluajit", "Libplacebo",
                "Libshaderc_combined", "Libsmbclient", "Libssl", "Libuchardet",
                "Libunibreak", "gmp", "gnutls", "hogweed", "lcms2", "nettle",
                "MoltenVK"
            ],
            path: "Sources/MPVKit",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Security"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("OpenGL", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS])),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("resolv"),
                .linkedLibrary("c++"),
                .linkedLibrary("expat"),
                .linkedLibrary("MoltenVK")
            ]
        ),
        .binaryTarget(name: "Libmpv", path: "XCFrameworks/Libmpv.xcframework"),
        .binaryTarget(name: "Libavcodec", path: "XCFrameworks/Libavcodec.xcframework"),
        .binaryTarget(name: "Libavdevice", path: "XCFrameworks/Libavdevice.xcframework"),
        .binaryTarget(name: "Libavfilter", path: "XCFrameworks/Libavfilter.xcframework"),
        .binaryTarget(name: "Libavformat", path: "XCFrameworks/Libavformat.xcframework"),
        .binaryTarget(name: "Libavutil", path: "XCFrameworks/Libavutil.xcframework"),
        .binaryTarget(name: "Libswresample", path: "XCFrameworks/Libswresample.xcframework"),
        .binaryTarget(name: "Libswscale", path: "XCFrameworks/Libswscale.xcframework"),
        .binaryTarget(name: "Libass", path: "XCFrameworks/Libass.xcframework"),
        .binaryTarget(name: "Libbluray", path: "XCFrameworks/Libbluray.xcframework"),
        .binaryTarget(name: "Libcrypto", path: "XCFrameworks/Libcrypto.xcframework"),
        .binaryTarget(name: "Libdav1d", path: "XCFrameworks/Libdav1d.xcframework"),
        .binaryTarget(name: "Libdovi", path: "XCFrameworks/Libdovi.xcframework"),
        .binaryTarget(name: "Libfreetype", path: "XCFrameworks/Libfreetype.xcframework"),
        .binaryTarget(name: "Libuavs3d", path: "XCFrameworks/Libuavs3d.xcframework"),
        .binaryTarget(name: "Libfribidi", path: "XCFrameworks/Libfribidi.xcframework"),
        .binaryTarget(name: "Libharfbuzz", path: "XCFrameworks/Libharfbuzz.xcframework"),
        .binaryTarget(name: "Libluajit", path: "XCFrameworks/Libluajit.xcframework"),
        .binaryTarget(name: "Libplacebo", path: "XCFrameworks/Libplacebo.xcframework"),
        .binaryTarget(name: "Libshaderc_combined", path: "XCFrameworks/Libshaderc_combined.xcframework"),
        .binaryTarget(name: "Libsmbclient", path: "XCFrameworks/Libsmbclient.xcframework"),
        .binaryTarget(name: "Libssl", path: "XCFrameworks/Libssl.xcframework"),
        .binaryTarget(name: "Libuchardet", path: "XCFrameworks/Libuchardet.xcframework"),
        .binaryTarget(name: "Libunibreak", path: "XCFrameworks/Libunibreak.xcframework"),
        .binaryTarget(name: "gmp", path: "XCFrameworks/gmp.xcframework"),
        .binaryTarget(name: "gnutls", path: "XCFrameworks/gnutls.xcframework"),
        .binaryTarget(name: "hogweed", path: "XCFrameworks/hogweed.xcframework"),
        .binaryTarget(name: "lcms2", path: "XCFrameworks/lcms2.xcframework"),
        .binaryTarget(name: "nettle", path: "XCFrameworks/nettle.xcframework"),
        .binaryTarget(name: "MoltenVK", path: "XCFrameworks/MoltenVK.xcframework")
    ]
)
