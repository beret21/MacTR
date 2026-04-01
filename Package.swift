// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacTR",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .target(
            name: "CThermalSensor",
            path: "Sources/CThermalSensor",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "MacTR",
            dependencies: [
                "CLibUSB",
                "CThermalSensor",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MacTR",
            swiftSettings: [
                .unsafeFlags(["-I/opt/homebrew/include/libusb-1.0"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"]),
                .linkedLibrary("usb-1.0"),
            ]
        ),
    ]
)
