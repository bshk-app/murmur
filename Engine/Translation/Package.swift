// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"MurmurTranslation", platforms:[.macOS(.v15),.iOS(.v18)], products:[.library(name:"MurmurTranslation",targets:["MurmurTranslation"])],dependencies:[.package(path:"../Core")],targets:[
 .binaryTarget(name:"MurmurMT",path:"Artifacts/MurmurMT.xcframework"),
 .target(name:"MurmurTranslation",dependencies:["MurmurMT",.product(name:"MurmurCore",package:"Core")],linkerSettings:[.linkedFramework("Accelerate"),.linkedLibrary("c++"),.linkedLibrary("iconv"),.linkedLibrary("pcre2-8",.when(platforms:[.macOS]))]),
 .testTarget(name:"MurmurTranslationTests",dependencies:["MurmurTranslation"],path:"Tests/MurmurTranslationTests")
],swiftLanguageModes:[.v5])
