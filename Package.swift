// swift-tools-version:5.9
import PackageDescription

// llama.cpp は scripts/build-llama.sh で vendor/llama (include/, lib/) にビルド・インストールされる。
let llamaLib = "vendor/llama/lib"

let package = Package(
    name: "Tsumugi",
    platforms: [.macOS(.v13)],
    targets: [
        // 変換エンジン・学習・入力セッション (純 Swift、UI 非依存)
        .target(name: "TsumugiCore"),
        .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
        // llama.cpp を使ったローカル LLM 補助
        .target(
            name: "TsumugiLLM",
            dependencies: ["TsumugiCore", "CLlama"],
            linkerSettings: [
                .unsafeFlags(["-L", llamaLib]),
                .linkedLibrary("llama"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
                .linkedLibrary("ggml-cpu"),
                .linkedLibrary("ggml-metal"),
                .linkedLibrary("ggml-blas"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        // 候補ウインドウ・予測ピルなど IME とプレイグラウンドで共有する UI
        .target(name: "TsumugiUI", dependencies: ["TsumugiCore", "TsumugiLLM"]),
        .executableTarget(name: "TsumugiIME", dependencies: ["TsumugiCore", "TsumugiLLM", "TsumugiUI"]),
        .executableTarget(name: "TsumugiPlayground", dependencies: ["TsumugiCore", "TsumugiLLM", "TsumugiUI"]),
        .executableTarget(name: "tsumugi-cli", dependencies: ["TsumugiCore", "TsumugiLLM"]),
        .testTarget(name: "TsumugiCoreTests", dependencies: ["TsumugiCore"]),
    ]
)
