// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "web-gateway",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "AppCore", targets: ["AppCore"]),
    .executable(name: "web-gateway", targets: ["AppCLI"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    .package(url: "https://github.com/tacogips/agent-gateway.git", from: "0.1.2")
  ],
  targets: [
    .systemLibrary(
      name: "CSQLite",
      providers: [
        .apt(["libsqlite3-dev"]),
        .brew(["sqlite3"])
      ]
    ),
    .target(
      name: "AppCore",
      dependencies: [
        "CSQLite",
        .product(name: "SwiftSoup", package: "SwiftSoup"),
        .product(name: "ACP", package: "agent-gateway"),
        .product(name: "AgentGateway", package: "agent-gateway"),
        .product(name: "AgentGatewayAppCore", package: "agent-gateway")
      ]
    ),
    .executableTarget(
      name: "AppCLI",
      dependencies: [
        "AppCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ]
    ),
    .testTarget(
      name: "AppCoreTests",
      dependencies: ["AppCore"]
    )
  ],
  swiftLanguageModes: [.v6]
)
