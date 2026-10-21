// swift-tools-version: 5.9
import PackageDescription
// iOS-only distribution of upstream Sherpa 1.13.8, revision 11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf.
// Keeps unused macOS artifacts out of Xcode's dependency resolution.
let package = Package(name: "SherpaOnnxIOS", platforms: [.iOS(.v15)], products: [.library(name: "sherpa-onnx", targets: ["SherpaOnnx"])], targets: [
.binaryTarget(name: "SherpaOnnxIOS", url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-ios-static.xcframework.zip", checksum: "6b8e769cb153343270fdccbe92e3b3db0d1c421d67fa0989ab01fdf5b2fcf2de"),
.binaryTarget(name: "OnnxruntimeIOS", url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-ios-static-xcframework-1.28.2.xcframework.zip", checksum: "2c2299acbb461d26d4bac4bc85985d40e7c7177ed6072703ae0846d88b0b4599"),
.target(name: "SherpaOnnx", dependencies: ["SherpaOnnxIOS", "OnnxruntimeIOS"], linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreML")])])
