// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ARMetalLib",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ARMetalLib",
            targets: ["ARMetalLib"]),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "ARMetalLib",
            resources: [
                .process("Shaders/Shader.metal")
            ]
        )
    ]
)

//// swift-tools-version:5.5
//import PackageDescription
//
//let package = Package(
//    name: "ARMetalSDK",
//    platforms: [
//        .iOS(.v13)
//    ],
//    products: [
//        .library(
//            name: "ARMetalSDK",
//            targets: ["ARMetalSDK"]),
//    ],
//    targets: [
//        .target(
//            name: "ARMetalSDK",
//            resources: [
//                .process("Shaders/Shaders.metal")
//            ]
//        )
//    ]
//)
