// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacTR",
    platforms: [
        .macOS(.v26)
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
            dependencies: ["CLibUSB", "CThermalSensor"],
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
