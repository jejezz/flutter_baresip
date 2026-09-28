// swift-tools-version: 5.9

import PackageDescription

// 영상 프레임을 Flutter 텍스처로 올리는 작은 macOS 플러그인. SIP 스택 자체는
// dart:ffi(hook/build.dart)로 싣고, 여기는 텍스처 등록만 한다.
let package = Package(
    name: "baresip_sip",
    platforms: [
        .macOS("12.0")
    ],
    products: [
        .library(name: "baresip-sip", targets: ["baresip_sip"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "baresip_sip",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
