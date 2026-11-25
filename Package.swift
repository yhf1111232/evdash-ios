// swift-tools-version:5.9
//
//  Package.swift 鈥斺€?鍙敤浜庤窇鍗忚閫昏緫娴嬭瘯锛坢acOS / Linux / Windows锛夈€?//  iOS App 鏈綋鐢?project.yml + XcodeGen 鏋勫缓锛屼笉缁忚繃 SwiftPM銆?//
//  鐢ㄦ硶锛歴wift test
//
//  璇存槑锛?//   - Tests/main.swift 鏄?Windows 涓婄殑鐙珛鍙墽琛岄獙璇侊紙椤跺眰浠ｇ爜锛夛紝
//     涓?XCTest 鐩爣浜掓枼锛屽洜姝?exclude銆?//   - EvDash/ 涓嬬殑 Apple-only 鏂囦欢锛圕oreBluetooth / SwiftUI锛変笉灞炰簬鏈寘锛?//     鏄惧紡 exclude 鎺夛紝閬垮厤 "unhandled files" 璀﹀憡銆?//
import PackageDescription

let package = Package(
    name: "EvDashCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v12)
    ],
    products: [
        .library(name: "EvDashCore", targets: ["EvDashCore"])
    ],
    targets: [
        .target(
            name: "EvDashCore",
            path: "EvDash",
            exclude: [
                "BleManager.swift",
                "ContentView.swift",
                "EvDashApp.swift",
                "Info.plist"
            ],
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
