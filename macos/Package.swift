// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QlickLab",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QlickLab", targets: ["QlickLab"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(name: "QlickLab", dependencies: ["Sparkle"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "QlickLabTests", dependencies: ["QlickLab"])
    ]
)
