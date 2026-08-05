// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "ConvexSwiftDemo",
  products: [
    .library(name: "Convex", targets: ["Convex"]),
    .executable(name: "convex-adapter", targets: ["ConvexAdapter"]),
    .executable(name: "convex-example", targets: ["ConvexExample"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
    .package(url: "https://github.com/vapor/websocket-kit.git", exact: "2.15.0"),
  ],
  targets: [
    .target(
      name: "Convex",
      dependencies: [.product(name: "WebSocketKit", package: "websocket-kit")],
      path: ".",
      exclude: ["Package.swift", "Package.resolved", "tests", "examples"],
      sources: ["Convex.swift", "Live.swift"]
    ),
    .target(name: "AdapterCore", dependencies: ["Convex"], path: "tests/conformance/core"),
    .executableTarget(
      name: "ConvexAdapter", dependencies: ["AdapterCore"], path: "tests/conformance/main"),
    .executableTarget(name: "ConvexExample", dependencies: ["Convex"], path: "examples/basics"),
    .testTarget(
      name: "ConvexTests",
      dependencies: ["Convex", "AdapterCore", .product(name: "Crypto", package: "swift-crypto")],
      path: "tests/unit"),
  ]
)
