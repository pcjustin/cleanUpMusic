// swift-tools-version:6.0
import PackageDescription

// Core (models + controllers) is shared; each platform adds its own views: SwiftUI on macOS, and on Windows a DLL
// the WinUI app in `windows/` calls. Windows finds TagLib and OpenCC through vcpkg (see windows/build.ps1).
var products: [Product] = []
var targets: [Target] = [
    .systemLibrary(name: "CTagLib", pkgConfig: "taglib_c", providers: [.brew(["taglib"])]),
    .systemLibrary(name: "COpenCC", pkgConfig: "opencc", providers: [.brew(["opencc"])]),
    .target(name: "CleanUpMusicCore", dependencies: ["CTagLib", "COpenCC"]),
    .testTarget(name: "CleanUpMusicTests", dependencies: ["CleanUpMusicCore"]),
]
#if os(Windows)
products.append(.library(name: "CleanUpMusicBridge", type: .dynamic, targets: ["CleanUpMusicBridge"]))
targets.append(.target(name: "CleanUpMusicBridge", dependencies: ["CleanUpMusicCore"]))
#else
targets.append(.executableTarget(name: "CleanUpMusic", dependencies: ["CleanUpMusicCore"], resources: [.copy("Resources/AppIcon.svg")]))
#endif

let package = Package(
    name: "CleanUpMusic",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
