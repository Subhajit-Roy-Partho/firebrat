// swift-tools-version: 5.9
import PackageDescription
import Foundation
// Official llama.cpp b11797, rebuilt with its own build-xcframework.sh for both
// ios-sim and ios-device. Reproduction instructions accompany the runtime.
let local = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Artifacts/llama.xcframework")
let runtime: Target = local ? .binaryTarget(name: "llama", path: "Artifacts/llama.xcframework") : .binaryTarget(name: "llama", url: "https://github.com/Subhajit-Roy-Partho/firebrat/releases/download/v1.6.0/firebrat-llama-b11797-ios.xcframework.zip", checksum: "ec3999c16d67ecf9b784ef72447e8376a39b1c2fe9496fda2989f08e2f5e44e7")
let package = Package(name: "LlamaIOS", platforms: [.iOS(.v17)], products: [.library(name: "llama", targets: ["llama"])], targets: [runtime])
