// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CleanUpMusic",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CTagLib", pkgConfig: "taglib_c", providers: [.brew(["taglib"])]),
        .systemLibrary(name: "COpenCC", pkgConfig: "opencc", providers: [.brew(["opencc"])]),
        .executableTarget(name: "CleanUpMusic", dependencies: ["CTagLib", "COpenCC"]),
        .testTarget(name: "CleanUpMusicTests", dependencies: ["CleanUpMusic"]),
    ],
    swiftLanguageModes: [.v5]
)
