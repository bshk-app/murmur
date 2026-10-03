// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MurmurOCR", platforms: [.iOS(.v18)], products: [.library(name: "MurmurOCR", targets: ["MurmurOCR"])], targets: [
    .binaryTarget(name: "opencv2", path: "Artifacts/opencv2.xcframework"),
    .binaryTarget(name: "onnxruntime", path: "Artifacts/onnxruntime.xcframework"),
    .binaryTarget(name: "onnxruntime_objc", path: "Artifacts/onnxruntime_objc.xcframework"),
    .target(name: "COCR", dependencies: ["opencv2", "onnxruntime", "onnxruntime_objc"], exclude: ["clipper.cpp"], sources: ["Bridge.mm", "ClipperWrapper.mm"], publicHeadersPath: "include", cxxSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("z"), .linkedFramework("Accelerate"), .linkedFramework("UIKit")]),
    .target(name: "MurmurOCR", dependencies: ["COCR"], resources: [.process("Resources")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-ObjC"])])
], swiftLanguageModes: [.v5], cxxLanguageStandard: .cxx17)
