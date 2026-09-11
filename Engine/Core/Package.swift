// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MurmurCore", platforms: [.macOS(.v14), .iOS(.v18)], products: [.library(name:"MurmurCore",targets:["MurmurCore"])], dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")
], targets: [.target(name:"MurmurCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]), .testTarget(name:"MurmurCoreTests",dependencies:["MurmurCore"])], swiftLanguageModes:[.v5])
