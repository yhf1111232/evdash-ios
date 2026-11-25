// swift-tools-version:5.9
//
//  Package.swift —— 只用于跑协议逻辑测试。
//  iOS App 本体用 project.yml + XcodeGen 构建，不经过 SwiftPM。
//
//  用法（macOS / Linux / Windows 均可）：
//      swift test
//
//  说明：Tests/main.swift 是 Windows 上的独立可执行验证（顶层代码），
//        与 XCTest 测试目标互斥，因此这里 exclude 掉。
//
import PackageDescription

let package = Package(
    name: "EvDashCore",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "EvDashCore", targets: ["EvDashCore"])
    ],
    targets: [
        .target(
            name: "EvDashCore",
            path: "EvDash",
            sources: [
                "FrameDecoder.swift",
                "ParamCodec.swift",
                "Params.swift"
            ]
        ),
        .testTarget(
            name: "EvDashCoreTests",
            dependencies: ["EvDashCore"],
            path: "Tests",
            exclude: ["main.swift"]
        )
    ]
)
