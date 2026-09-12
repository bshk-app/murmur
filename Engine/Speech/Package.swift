// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"MurmurSpeech", platforms:[.macOS(.v15),.iOS(.v18)], products:[.library(name:"MurmurSpeech",targets:["MurmurSpeech"])], dependencies:[
 .package(path:"../Core"), .package(path:"Vendor/mlx-audio-swift"),
 .package(url:"https://github.com/ml-explore/mlx-swift.git", exact:"0.31.6"),
 .package(url:"https://github.com/huggingface/swift-huggingface.git", exact:"0.10.0"),
 .package(url:"https://github.com/beshkenadze/FluidAudio.git", revision:"4ef33f0b64837c2943e8cd0f66940d5861176d6a"),
 .package(url:"https://github.com/argmaxinc/argmax-oss-swift.git", exact:"1.1.0")
], targets:[.target(name:"MurmurSpeech",dependencies:[.product(name:"MurmurCore",package:"Core"), .product(name:"MLXAudioSTT",package:"mlx-audio-swift"),.product(name:"MLXAudioVAD",package:"mlx-audio-swift"),.product(name:"MLX",package:"mlx-swift"),.product(name:"HuggingFace",package:"swift-huggingface"),.product(name:"FluidAudio",package:"FluidAudio"),.product(name:"WhisperKit",package:"argmax-oss-swift")],exclude:["CohereCoreML/LICENSE.txt","CanaryQualification/NOTICE.md","CanaryQualification/LICENSE-FluidAudio"], linkerSettings:[.linkedFramework("Accelerate")])],swiftLanguageModes:[.v5])
