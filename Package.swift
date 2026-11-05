// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FigmaCapture",
    platforms: [.iOS(.v15)],
    products: [.library(name: "FigmaCapture", targets: ["FigmaCapture"])],
    targets: [.target(name: "FigmaCapture")]
)
