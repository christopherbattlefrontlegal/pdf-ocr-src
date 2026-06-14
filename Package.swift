// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "pdf-ocr",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "pdf-ocr", path: "Sources/pdf-ocr")
    ]
)
